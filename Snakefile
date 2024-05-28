###########################################################################
# Genome annotation pipeline using braker in Snakemake
# Snakemake/5.13.0
###########################################################################
from os.path import join
from snakemake.io import expand, glob_wildcards

result_dir = config["result_dir"]
input_dir = config["input_dir"]
rna_dir = config["rna_dir"]

protein_file = config["protein_file"]
rna_list = config["rna_list"]

SAMPLE = list(glob_wildcards(join(input_dir, "{ids}.fasta")))[0]

print(SAMPLE)

rule All:
    input:
        # Repeats
        expand(join(result_dir,"{samples}-families.fa"),samples=SAMPLE),
        expand(join(result_dir,"{samples}.softMasked.fasta"),samples=SAMPLE),
        expand(join(result_dir,"{samples}.fasta.masked"),samples=SAMPLE),
        expand(join(result_dir,"{samples}.fasta.out.gff"),samples=SAMPLE),

        # braker files
        expand(join(result_dir, "{samples}_braker/trna.gff3"),samples=SAMPLE),
        expand(join(result_dir,"{samples}_braker/braker.gff3"),samples=SAMPLE),
        expand(join(result_dir,"{samples}_braker/braker.aa"),samples=SAMPLE),
        expand(join(result_dir,"{samples}_braker/braker.codingseq"),samples=SAMPLE),

        # renamed file
        expand(join(result_dir,"{samples}_braker.gff3"),samples=SAMPLE),
        expand(join(result_dir,"{samples}_braker.prot"),samples=SAMPLE),
        expand(join(result_dir,"{samples}_braker.cds"),samples=SAMPLE),

        # functional file
        expand(join(result_dir,"{samples}_braker.functional.gff3"),samples=SAMPLE),
        expand(join(result_dir,"{samples}_braker.functional.gtf"),samples=SAMPLE),
        expand(join(result_dir,"{samples}_braker.functional.clean.gtf"),samples=SAMPLE),
        expand(join(result_dir,"{samples}_braker.functional.aa"),samples=SAMPLE),
        expand(join(result_dir,"{samples}_braker.functional.cds"),samples=SAMPLE),

# Blasts genome against itself to identify highly repetitve regions which it then attempts to classify.
rule RepeatModeler:
  input:
    fa=join(input_dir, "{samples}.fasta"),
  output:
    fa=join(result_dir, "{samples}.fasta"),
    rep=join(result_dir,"{samples}-families.fa"),
  params:
    rname="RepeatModeler",
    dir=result_dir,
    id="{samples}",
  threads:
    48
  shell:
    """
    cd {params.dir}
    module load repeatmodeler
    ln -s {input.fa} {output.fa}
    BuildDatabase -name {params.id} {output.fa}
    RepeatModeler -database {params.id} -pa {threads} -LTRStruct >& {params.id}.out
    """

# Blasts genome using generated repeats to identify the loci for each repeat.
rule RepeatMasker:
  input:
    fa=join(result_dir, "{samples}.fasta"),
    rep=join(result_dir,"{samples}-families.fa"),
  output:
    fa=join(result_dir,"{samples}.fasta.masked"),
    gff=join(result_dir,"{samples}.fasta.out.gff"),
  params:
    rname="RepeatMasker",
    dir=result_dir,
    threads="48",
  shell:
    """
    cd {params.dir}
    module load repeatmasker
    RepeatMasker -u -s -poly -engine rmblast -pa {params.threads} -gff -no_is -gccalc -norna -lib {input.rep} {input.fa}
    """

# Softmask repeats in genome for braker step
rule softMask:
    input:
        fa=join(result_dir, "{samples}.fasta"),
        gff=join(result_dir,"{samples}.fasta.out.gff"),
    output:
        fa=join(result_dir, "{samples}.softMasked.fasta"),
    params:
        rname="softMask",
    shell:
        """
        module load bedtools
        bedtools maskfasta -fullHeader -soft -fi {input.fa} -bed {input.gff} -fo {output.fa}
        """

# Identifies and annotates genes and transcripts in the softmasked genome, using protein sequences and bulk RNAseq data.
rule braker:
    input:
        fa=join(result_dir, "{samples}.softMasked.fasta"),
    output:
        gff=join(result_dir, "{samples}_braker/braker.gff3"),
        aa=join(result_dir, "{samples}_braker/braker.aa"),
        cds=join(result_dir, "{samples}_braker/braker.codingseq"),
    params:
        rname="braker",
        species_id="{samples}",
        out_dir=join(result_dir,"{samples}_braker"),
        rna_dir=rna_dir,
        rna_list=rna_list,
        prot=protein_file,
    shell:
        """
        module load braker
        mkdir -p {params.out_dir}
        braker.pl --genome={input.fa} --useexisting --species={params.species_id} \
        --prot_seq={params.prot} --workingdir={params.out_dir} \
        --gff3 --threads=8 --rnaseq_sets_ids={params.rna_list}  \
        --rnaseq_sets_dir={params.rna_dir}
        """
rule trnascan:
    input:
        fa=join(result_dir, "{samples}.softMasked.fasta"),
    output:
        gff=join(result_dir, "{samples}_braker/trna.gff3"),
    params:
        rname="trnascan",
    shell:
        """
        module load trnascan-se/2.0.9
        tRNAscan-SE -j {output.gff} {input.fa}
        """


# Rename gene IDs with custom ID
rule gff_rename:
    input:
        gff=join(result_dir, "{samples}_braker/braker.gff3"),
        aa=join(result_dir, "{samples}_braker/braker.aa"),
        cds=join(result_dir, "{samples}_braker/braker.codingseq"),
    output:
        map=temp(join(result_dir, "{samples}.map")),
        gff=join(result_dir, "{samples}_braker.gff3"),
        aa=join(result_dir, "{samples}_braker.prot"),
        cds=join(result_dir, "{samples}_braker.cds"),
    params:
        species_id="{samples}",
        rname="gff_rename",
    shell:
        """
        module load maker
        maker_map_ids --prefix {params.species_id} --justify 5  {input.gff} > {output.map}
        cp {input.gff} {output.gff}
        map_gff_ids {output.map} {output.gff}
        cp {input.aa} {output.aa}
        cp {input.cds} {output.cds}
        map_fasta_ids {output.map} {output.aa}
        map_fasta_ids {output.map} {output.cds}
        """

# Annotate genes with functional use based on uniprot DB
# Note, if you are not using the default uniprot protein DB, you must make your custom protein fasta file a blastp database before running this step.
rule gff_annot:
    input:
        gff=join(result_dir, "{samples}_braker.gff3"),
        prot=join(result_dir, "{samples}_braker.prot"),
        cds=join(result_dir, "{samples}_braker.cds"),
    output:
        gff=join(result_dir, "{samples}_braker.functional.gff3"),
        prot=join(result_dir, "{samples}_braker.functional.aa"),
        cds=join(result_dir, "{samples}_braker.functional.cds"),
        blast=temp(join(result_dir,"{samples}.blast")),
    params:
        rname="gff_annot",
        threads=8,
        uniprot=protein_file,
    shell:
        """
        module load blast maker
        blastp -query {input.prot} -db {params.uniprot} -evalue 1e-6 -max_hsps 1 -max_target_seqs 1 -outfmt 6 -out {output.blast} -num_threads {params.threads}
        maker_functional_gff {params.uniprot} {output.blast} {input.gff} > {output.gff}
        maker_functional_fasta {params.uniprot} {output.blast} {input.prot} > {output.prot}
        maker_functional_fasta {params.uniprot} {output.blast} {input.cds} > {output.cds}
        """

# Clean & convert gff to gtf for use in RNA-seek
rule gff2gtf:
    input:
        gff1=join(result_dir, "{samples}_braker/trna.gff3"),
        gff2=join(result_dir,"{samples}_braker.functional.gff3"),
    output:
        gff=temp(join(result_dir,"{samples}_braker.functional.gff")),
        gtf=join(result_dir,"{samples}_braker.functional.gtf"),
        clean=join(result_dir,"{samples}_braker.functional.clean.gtf"),
    params:
        rname="gff2gtf",
    shell:
        """
        module load agat/1.2.0 python
        agat_sp_merge_annotations.pl --gff {input.gff1} --gff {input.gff2} --out (output.gff)
        agat_convert_sp_gff2gtf.pl --gff {output.gff} -o {output.gtf}
        python /data/OpenOmics/references/brakerMake/clean_gtf.py {output.gtf} > {output.clean}
        """
