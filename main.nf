#!/usr/bin/env nextflow

def helpMessage() {
    log.info"""
    Usage: 
    An example command for running the pipeline is as follows:
    nextflow run greninger-lab/covid_swift_pipeline -resume -with-docker ubuntu:18.04 --INPUT example/ --OUTDIR example/output/
    
    Parameters:
        --INPUT         Input folder where all fastqs are located.
                        ./ can be used for current directory.
                        Fastqs should all be gzipped. This can be done with the command gzip *.fastq. [REQUIRED]
        --OUTDIR        Output directory. [REQUIRED]
        --SINGLE_END    Optional flag for single end reads. By default, this pipeline does 
                        paired-end reads.

        -with-docker ubuntu:18.04   [REQUIRED]
        -resume [RECOMMENDED]
        
    """.stripIndent()
}

/*
 * SET UP CONFIGURATION VARIABLES
 */

// Show help message
params.help = false
if (params.help){
    helpMessage()
    exit 0
}

params.INPUT = false
params.OUTDIR= false
params.SINGLE_END = false
TRIM_ENDS=file("${baseDir}/trim_ends.py")

// if INPUT not set
if (params.INPUT == false) {
    println( "Must provide an input directory with --INPUT") 
    exit(1)
}
// Make sure INPUT ends with trailing slash
if (!params.INPUT.endsWith("/")){
    println("Make sure your input directory ends with trailing slash.")
   exit(1)
}
// if OUTDIR not set
if (params.OUTDIR == false) {
    println( "Must provide an output directory with --OUTDIR") 
    exit(1)
}
// Make sure OUTDIR ends with trailing slash
if (!params.OUTDIR.endsWith("/")){
   println("Make sure your output directory ends with trailing slash.")
   exit(1)
}

//files 
REFERENCE_FASTA = file("${baseDir}/NC_045512.2.fasta")
MASTERFILE = file("${baseDir}/sarscov2_masterfile.txt")
ADAPTERS = file("${baseDir}/All_adapters.fa")
FIX_COVERAGE = file("${baseDir}/fix_coverage.py")
PROTEINS = file("${baseDir}/NC_045512_proteins.txt")

if(params.SINGLE_END == false){ 
    input_read_ch = Channel
        .fromFilePairs("${params.INPUT}*_R{1,2}*.gz")
        .ifEmpty { error "Cannot find any FASTQ pairs in ${params.INPUT} ending with .gz" }
        .map { it -> [it[0], it[1][0], it[1][1]]}


process Trimming { 
    container "quay.io/biocontainers/trimmomatic:0.35--6"

	// Retry on fail at most three times 
    errorStrategy 'retry'
    maxRetries 3

    input:
      tuple val(base), file(R1), file(R2) from input_read_ch
      file ADAPTERS
    output: 
      tuple val(base), file("${base}.R1.paired.fastq.gz"), file("${base}.R2.paired.fastq.gz"),file("${base}.R1.unpaired.fastq.gz"), file("${base}.R2.unpaired.fastq.gz"),file("${base}_summary.csv"),file("${base}_log.txt") into Trim_out_ch
      tuple val(base), file(R1),file(R2),file("${base}.R1.paired.fastq.gz"), file("${base}.R2.paired.fastq.gz"),file("${base}.R1.unpaired.fastq.gz"), file("${base}.R2.unpaired.fastq.gz") into Trim_out_ch2

    publishDir "${params.OUTDIR}trimmed_fastqs", mode: 'copy',pattern:'*fastq*'

    script:
    """
    #!/bin/bash

    trimmomatic PE -threads ${task.cpus} ${R1} ${R2} ${base}.R1.paired.fastq.gz ${base}.R1.unpaired.fastq.gz ${base}.R2.paired.fastq.gz ${base}.R2.unpaired.fastq.gz \
    ILLUMINACLIP:${ADAPTERS}:2:30:10:1:true LEADING:3 TRAILING:3 SLIDINGWINDOW:4:20 MINLEN:75

    num_r1_untrimmed=\$(gunzip -c ${R1} | wc -l)
    num_r2_untrimmed=\$(gunzip -c ${R2} | wc -l)
    num_untrimmed=\$((\$((num_r1_untrimmed + num_r2_untrimmed))/4))

    num_r1_paired=\$(gunzip -c ${base}.R1.paired.fastq.gz | wc -l)
    num_r2_paired=\$(gunzip -c ${base}.R2.paired.fastq.gz | wc -l)
    num_paired=\$((\$((num_r1_paired + num_r2_paired))/4))

    num_r1_unpaired=\$(gunzip -c ${base}.R1.unpaired.fastq.gz | wc -l)
    num_r2_unpaired=\$(gunzip -c ${base}.R2.unpaired.fastq.gz | wc -l)
    num_unpaired=\$((\$((num_r1_unpaired + num_r2_unpaired))/4))

    num_trimmed=\$((num_paired + num_unpaired))
    
    percent_trimmed=\$((100-\$((100*num_trimmed/num_untrimmed))))
    
    echo Sample_Name,Raw_Reads,Trimmed_Paired_Reads,Trimmed_Unpaired_Reads,Total_Trimmed_Reads,Percent_Trimmed,Mapped_Reads,Clipped_Mapped_Reads,Mean_Coverage,Spike_Mean_Coverage,Spike_100X_Cov_Percentage,Spike_200X_Cov_Percentage,Percent_N > ${base}_summary.csv
    printf "${base},\$num_untrimmed,\$num_paired,\$num_unpaired,\$num_trimmed,\$percent_trimmed" >> ${base}_summary.csv
    
    cp .command.log ${base}_log.txt

    """
}

process fastQc {
    container "quay.io/biocontainers/fastqc:0.11.9--0"

	// Retry on fail at most three times 
    errorStrategy 'retry'
    maxRetries 3

    input:
      tuple val(base), file(R1),file(R2),file("${base}.R1.paired.fastq.gz"), file("${base}.R2.paired.fastq.gz"),file("${base}.R1.unpaired.fastq.gz"), file("${base}.R2.unpaired.fastq.gz") from Trim_out_ch2
    output: 
      file("*fastqc*") into Fastqc_ch 

    publishDir "${params.OUTDIR}fastqc", mode: 'copy'

    script:
    """
    #!/bin/bash

    /usr/local/bin/fastqc ${R1} ${R2} ${base}.R1.paired.fastq.gz ${base}.R2.paired.fastq.gz

    """
}

process Aligning {
     container "quay.io/biocontainers/bbmap:38.86--h1296035_0"
    //container "quay.io/biocontainers/bwa:0.7.17--hed695b0_7	"

    // Retry on fail at most three times 
    errorStrategy 'retry'
    maxRetries 3

    input: 
      tuple val(base), file("${base}.R1.paired.fastq.gz"), file("${base}.R2.paired.fastq.gz"),file("${base}.R1.unpaired.fastq.gz"), file("${base}.R2.unpaired.fastq.gz"),file("${base}_summary.csv"),file("${base}_log.txt") from Trim_out_ch
      file REFERENCE_FASTA
    output:
      tuple val(base), file("${base}.bam"),file("${base}_summary.csv"),file("${base}_log.txt") into Aligned_bam_ch

    cpus 4 
    memory '6 GB'

    script:
    """
    #!/bin/bash

    cat ${base}*.fastq.gz > ${base}_cat.fastq.gz
    /usr/local/bin/bbmap.sh in=${base}_cat.fastq.gz outm=${base}.bam ref=${REFERENCE_FASTA} -Xmx6g
    reads_mapped=\$(cat .command.log | grep "mapped:" | cut -d\$'\\t' -f3)
    printf ",\$reads_mapped" >> ${base}_summary.csv

    cat .command.log >> ${base}_log.txt

    """

    // bwa?
    // script:
    // """
    // #!/bin/bash
    // bwa mem $workflow.projectDir/NC_045512.2.fasta ${base}.R1.paired.fastq.gz ${base}.R2.paired.fastq.gz > aln.sam
    // """
}

// Single end first three steps
} else { 
    input_read_ch = Channel
        .fromPath("${params.INPUT}*.gz")
        //.map { it -> [ file(it)]}
        .map { it -> file(it)}
    
process Trimming_SE { 
    container "quay.io/biocontainers/trimmomatic:0.35--6"

	// Retry on fail at most three times 
    errorStrategy 'retry'
    maxRetries 3

    input:
      file R1 from input_read_ch
      file ADAPTERS
    output: 
      tuple env(base),file("*.trimmed.fastq.gz"),file("*summary.csv"),file("*log.txt") into Trim_out_ch_SE
      tuple env(base),file("*.trimmed.fastq.gz") into Trim_out_ch2_SE

    publishDir "${params.OUTDIR}trimmed_fastqs", mode: 'copy',pattern:'*fastq*'

    script:
    """
    #!/bin/bash

    base=`basename ${R1} ".fastq.gz"`

    echo \$base

    trimmomatic SE -threads ${task.cpus} ${R1} \$base.trimmed.fastq.gz \
    ILLUMINACLIP:${ADAPTERS}:2:30:10:1:true LEADING:3 TRAILING:3 SLIDINGWINDOW:4:20 MINLEN:75

    num_untrimmed=\$((\$(gunzip -c ${R1} | wc -l)/4))
    num_trimmed=\$((\$(gunzip -c \$base'.trimmed.fastq.gz' | wc -l)/4))
    
    percent_trimmed=\$((100-\$((100*num_trimmed/num_untrimmed))))
    
    echo Sample_Name,Raw_Reads,Trimmed_Reads,Percent_Trimmed,Mapped_Reads,Clipped_Mapped_Reads,Mean_Coverage,Spike_Mean_Coverage,Spike_100X_Cov_Percentage,Spike_200X_Cov_Percentage,Percent_N > \$base'_summary.csv'
    printf "\$base,\$num_untrimmed,\$num_trimmed,\$percent_trimmed" >> \$base'_summary.csv'
    
    cp .command.log \$base'_log.txt'

    ls -latr
    """
}

process fastQc_SE {
    container "quay.io/biocontainers/fastqc:0.11.9--0"

	// Retry on fail at most three times 
    errorStrategy 'retry'
    maxRetries 3

    input:
      tuple val(base),file("${base}.trimmed.fastq.gz") from Trim_out_ch2_SE
    output: 
      file("*fastqc*") into Fastqc_ch 

    publishDir "${params.OUTDIR}fastqc", mode: 'copy'

    script:
    """
    #!/bin/bash

    /usr/local/bin/fastqc ${base}.trimmed.fastq.gz
    """
}

process Aligning_SE {
     container "quay.io/biocontainers/bbmap:38.86--h1296035_0"
    //container "quay.io/biocontainers/bwa:0.7.17--hed695b0_7	"

    // Retry on fail at most three times 
    errorStrategy 'retry'
    maxRetries 3

    input: 
      tuple val(base),file("${base}.trimmed.fastq.gz"),file("${base}_summary.csv"),file("${base}_log.txt") from Trim_out_ch_SE
      file REFERENCE_FASTA
    output:
      tuple val (base), file("${base}.bam"),file("${base}_summary.csv"),file("${base}_log.txt") into Aligned_bam_ch

    cpus 4 
    memory '6 GB'

    script:
    """
    #!/bin/bash

    base=`basename ${base}.trimmed.fastq.gz ".trimmed.fastq.gz"`
    /usr/local/bin/bbmap.sh in1="\$base".trimmed.fastq.gz  outm="\$base".bam ref=${REFERENCE_FASTA} -Xmx6g sam=1.3
    reads_mapped=\$(cat .command.log | grep "mapped:" | cut -d\$'\\t' -f3)
    printf ",\$reads_mapped" >> ${base}_summary.csv

    cat .command.log >> ${base}_log.txt

    """
}
}

process NameSorting { 
    container "quay.io/biocontainers/samtools:1.3--h0592bc0_3"

	// Retry on fail at most three times 
    errorStrategy 'retry'
    maxRetries 3

    input:
      tuple val (base), file("${base}.bam"),file("${base}_summary.csv"),file("${base}_log.txt") from Aligned_bam_ch
    output:
      tuple val (base), file("${base}.sorted.sam"),file("${base}_summary.csv"),file("${base}_log.txt") into Sorted_sam_ch

    script:
    """
    #!/bin/bash
    samtools sort -@ ${task.cpus} -n -O sam ${base}.bam > ${base}.sorted.sam

    cat .command.log >> ${base}_log.txt

    """
}

process Clipping { 
    container "quay.io/greninger-lab/swift-pipeline:latest"

	// Retry on fail at most three times 
    errorStrategy 'retry'
    maxRetries 3

    input:
      tuple val (base), file("${base}.sorted.sam"),file("${base}_summary.csv"),file("${base}_log.txt") from Sorted_sam_ch
      file MASTERFILE
    output:
      tuple val (base), file("${base}.clipped.bam"), file("*.bai"),file("${base}_summary.csv"),file("${base}_log.txt") into Clipped_bam_ch
      tuple val (base), file("${base}.clipped.bam"), file("*.bai") into Clipped_bam_ch2

    script:
    // Paired end primerclip option
    if(params.SINGLE_END == false) { 
        """
        #!/bin/bash
        /./root/.local/bin/primerclip ${MASTERFILE} ${base}.sorted.sam ${base}.clipped.sam
        #/usr/local/miniconda/bin/samtools sort -@ ${task.cpus} -n -O sam ${base}.clipped.sam > ${base}.clipped.sorted.sam
        #/usr/local/miniconda/bin/samtools view -@ ${task.cpus} -Sb ${base}.clipped.sorted.sam > ${base}.clipped.unsorted.bam
        #/usr/local/miniconda/bin/samtools sort -@ ${task.cpus} -o ${base}.clipped.unsorted.bam ${base}.clipped.bam
        /usr/local/miniconda/bin/samtools sort -@ ${task.cpus} ${base}.clipped.sam -o ${base}.clipped.bam
        /usr/local/miniconda/bin/samtools index ${base}.clipped.bam

        clipped_reads=\$(cat .command.log | grep "Total mapped alignments" | cut -d\$'\\t' -f2)

        meancoverage=\$(/usr/local/miniconda/bin/samtools depth -a ${base}.clipped.bam | awk '{sum+=\$3} END { print sum/NR}')
        printf ",\$clipped_reads,\$meancoverage" >> ${base}_summary.csv

        cat .command.log >> ${base}_log.txt

        """
    }
    // Single end primerclip option
    else {
        """
        #!/bin/bash
        /./root/.local/bin/primerclip -s ${MASTERFILE} ${base}.sorted.sam ${base}.clipped.sam
        #/usr/local/miniconda/bin/samtools sort -@ ${task.cpus} -n -O sam ${base}.clipped.sam > ${base}.clipped.sorted.sam
        #/usr/local/miniconda/bin/samtools view -@ ${task.cpus} -Sb ${base}.clipped.sorted.sam > ${base}.clipped.unsorted.bam
        #/usr/local/miniconda/bin/samtools sort -@ ${task.cpus} -o ${base}.clipped.unsorted.bam ${base}.clipped.bam
        /usr/local/miniconda/bin/samtools sort -@ ${task.cpus} ${base}.clipped.sam -o ${base}.clipped.bam
        /usr/local/miniconda/bin/samtools index ${base}.clipped.bam

        clipped_reads=\$(cat .command.log | grep "Total mapped alignments" | cut -d\$'\\t' -f2)

        meancoverage=\$(/usr/local/miniconda/bin/samtools depth -a ${base}.clipped.bam | awk '{sum+=\$3} END { print sum/NR}')
        printf ",\$clipped_reads,\$meancoverage" >> ${base}_summary.csv

        cat .command.log >> ${base}_log.txt

        """
    }

    
}

process lofreq {
    container "quay.io/biocontainers/lofreq:2.1.5--py38h1bd3507_3"

	// Retry on fail at most three times 
    errorStrategy 'retry'
    maxRetries 3

    input:
      tuple val (base), file("${base}.clipped.bam"), file("*.bai") from Clipped_bam_ch2
      file REFERENCE_FASTA
    output:
      file("${base}_lofreq.vcf")
    
    publishDir params.OUTDIR, mode: 'copy'

    script:
    """
    #!/bin/bash
    /usr/local/bin/lofreq call -f ${REFERENCE_FASTA} -o ${base}_lofreq.vcf ${base}.clipped.bam

    """
}

process generateConsensus {
    container "quay.io/greninger-lab/swift-pipeline:latest"

	// Retry on fail at most three times 
    errorStrategy 'retry'
    maxRetries 3

    input:
        tuple val (base), file(BAMFILE),file(INDEX_FILE),file("${base}_summary.csv"),file("${base}_log.txt") from Clipped_bam_ch
        file REFERENCE_FASTA
        file TRIM_ENDS
        file FIX_COVERAGE
    output:
        file("${base}_swift.fasta")
        file("${base}.clipped.bam")
        file("${base}_bcftools.vcf")
        file("${base}.pileup")
        file(INDEX_FILE)
        file("${base}_summary.csv")

    publishDir params.OUTDIR, mode: 'copy'

    shell:
    '''
    #!/bin/bash
    ls -latr

    R1=`basename !{BAMFILE} .clipped.bam`

    # Using LAVA consensus calling!
    /usr/local/miniconda/bin/bcftools mpileup \\
        --count-orphans \\
        --no-BAQ \\
        --max-depth 500000 \\
        --max-idepth 500000 \\
        --fasta-ref !{REFERENCE_FASTA} \\
        --annotate FORMAT/AD,FORMAT/ADF,FORMAT/ADR,FORMAT/DP,FORMAT/SP,INFO/AD,INFO/ADF,INFO/ADR \\
        --threads 10 \\
        !{BAMFILE} > \${R1}.pileup
    
    cat \${R1}.pileup | /usr/local/miniconda/bin/bcftools call -m -Oz -o \${R1}_pre.vcf.gz
    
    /usr/local/miniconda/bin/tabix \${R1}_pre.vcf.gz
    gunzip \${R1}_pre.vcf.gz
     /usr/local/miniconda/bin/bcftools filter -i '(DP4[0]+DP4[1]) < (DP4[2]+DP4[3]) && ((DP4[2]+DP4[3]) > 0)' \${R1}_pre.vcf -o \${R1}.vcf
    /usr/local/miniconda/bin/bgzip \${R1}.vcf
    /usr/local/miniconda/bin/tabix \${R1}.vcf.gz 
    cat !{REFERENCE_FASTA} | /usr/local/miniconda/bin/bcftools consensus \${R1}.vcf.gz > \${R1}.consensus.fa

    if [ -s !{BAMFILE} ]
    then
        /usr/local/miniconda/bin/bedtools genomecov \\
            -bga \\
            -ibam !{BAMFILE} \\
            -g !{REFERENCE_FASTA} \\
            | awk '\$4 < 10' | /usr/local/miniconda/bin/bedtools merge > \${R1}.mask.bed
        /usr/local/miniconda/bin/bedtools maskfasta \\
        -fi \${R1}.consensus.fa \\
        -bed \${R1}.mask.bed \\
        -fo \${R1}.consensus.masked.fa

        cat !{REFERENCE_FASTA} \${R1}.consensus.masked.fa > align_input.fasta
        /usr/local/miniconda/bin/mafft --auto align_input.fasta > repositioned.fasta
        awk '/^>/ { print (NR==1 ? "" : RS) $0; next } { printf "%s", $0 } END { printf RS }' repositioned.fasta > repositioned_unwrap.fasta
        
        python3 !{TRIM_ENDS} \${R1}

        gunzip \${R1}.vcf.gz
        mv \${R1}.vcf \${R1}_bcftools.vcf
    else
       printf '>\$R1\n' > \${R1}_swift.fasta
       printf 'n%.0s' {1..29539}
    fi
    
    # Find percent ns, doesn't work, fix later in python script
    num_bases=$(grep -v ">" \${R1}_swift.fasta | wc | awk '{print $3-$1}')
    num_ns=$(grep -v ">" \${R1}_swift.fasta | awk -F"n" '{print NF-1}')
    percent_n=$(($num_ns/$num_bases*100))

    # Spike protein coverage
    /usr/local/miniconda/bin/samtools depth -a -r NC_045512.2:21563-25384 !{BAMFILE} > \${R1}_spike_coverage.txt
    avgcoverage=$(cat \${R1}_spike_coverage.txt | awk '{sum+=$3} END { print sum/NR}')
    proteinlength=$((25384-21563+1))
    cov100=$((100*$(cat \${R1}_spike_coverage.txt | awk '$3>=100' | wc -l)/3822))
    cov200=$((100*$(cat \${R1}_spike_coverage.txt | awk '$3>=200' | wc -l)/3822))

    printf ",\$avgcoverage,\$cov100,\$cov200,\$percent_n" >> \${R1}_summary.csv

    cat \${R1}_summary.csv | tr -d "[:blank:]" > a.tmp
    mv a.tmp \${R1}_summary.csv

    python3 !{FIX_COVERAGE} \${R1}
    mv \${R1}_summary_fixed.csv \${R1}_summary.csv

    [ -s \${R1}_swift.fasta ] || echo "WARNING: \${R1} produced blank output. Manual review may be needed."

    cat .command.log >> \${R1}_log.txt

    '''
}