#!/usr/bin/env bash

# Copyright 2025 Wen-Chin Huang (Nagoya University)
#  MIT License (https://opensource.org/licenses/MIT)

log() {
    local fname=${BASH_SOURCE[1]##*/}
    echo -e "$(date '+%Y-%m-%dT%H:%M:%S') (${fname}:${BASH_LINENO[0]}:${FUNCNAME[1]}) $*"
}

. ./path.sh || exit 1;
. ./cmd.sh || exit 1;

# basic settings
stage=-1       # stage to start
stop_stage=100 # stage to stop
verbose=1      # verbosity level (lower is less info)
n_gpus=1       # number of gpus in training
n_jobs=16      # number of parallel jobs in feature extraction

conf=conf/fastspeech2.v1.yaml

# dataset configuration
# db_root=downloads
db_root=/data/group1/z44476r/Corpora/jvs_ver1
dumpdir=dump                # directory to dump full features

# data preparation related
julius_clean=false

# pretrained model related
pretrained_model=           # NOTE(unilight): for future use

# training related setting
tag=""     # tag for directory to save model
resume=""  # checkpoint path to resume training
           # (e.g. <path>/<to>/checkpoint-10000steps.pkl)
           
# decoding related setting
outdir=                     # In case not evaluation not executed together with decoding & synthesis stage
voc=PWG                     # vocoder used (GL or PWG)
griffin_lim_iters=64        # number of iterations of Griffin-Lim
checkpoint=""               # checkpoint path to be used for decoding
                            # if not provided, the latest one will be used
                            # (e.g. <path>/<to>/checkpoint-400000steps.pkl)

# text related setting
oov="\<unk\>"         # Out of vocabrary symbol.
blank="\<blank\>"     # CTC blank symbol.
sos_eos="\<sos/eos\>" # sos and eos symbols.
token_type="phn"
nlsyms_txt=none  # Non-linguistic symbol list (needed if existing).
cleaner=tacotron # text cleaner.
g2p=g2p_en       # g2p method.

# shellcheck disable=SC1091
. utils/parse_options.sh || exit 1;

set -euo pipefail

train_set="train"
dev_set="dev"
test_set="test_parallel_with_ref"

token_listdir="${dumpdir}/token_list/${token_type}"
if [ "${cleaner}" != none ]; then
    token_listdir+="_${cleaner}"
fi
if [ "${token_type}" = phn ]; then
    token_listdir+="_${g2p}"
fi
token_list="${token_listdir}/tokens.txt"

# ========================== Main stages start from here. ==========================
                                       
if [ ${stage} -le -1 ] && [ ${stop_stage} -ge -1 ]; then
    log "stage -1: Data and pre-trained models downloading"

    # TODO(unilight): implement this
    local/data_download.sh ${db_root}
fi

if [ ${stage} -le 0 ] && [ ${stop_stage} -ge 0 ]; then
    log "stage 0: Data preparation"

    # for _set in "${train_set}" "${dev_set}" "${test_set}"; do
    #     log "Preparing ${_set} set"
    #     python local/data_prep_pre_julius.py \
    #         --original_csv "data/original_csvs/${_set}.csv" \
    #         --db_root "${db_root}" \
    #         --out "data/${_set}.pre_julius.csv"
    # done

    # local/run_julius.sh \
    #     --train_set "${train_set}" \
    #     --dev_set "${dev_set}" \
    #     --clean "${julius_clean}"

    for _set in "${train_set}" "${dev_set}"; do
        python local/data_prep_post_julius.py \
            --juliusdir "data/julius/tmp" \
            --conf "${conf}" \
            --original_csv "data/${_set}.pre_julius.csv" \
            --out "data/${_set}.csv"
    done

fi

if [ "${stage}" -le 1 ] && [ "${stop_stage}" -ge 1 ]; then
    echo "Stage 1: Feature extraction"
    # extract raw features
    pids=()
    for name in "${train_set}" "${dev_set}" "${eval_set}"; do
    (
        [ ! -e "${dumpdir}/${name}/raw" ] && mkdir -p "${dumpdir}/${name}/raw"
        echo "Feature extraction start. See the progress via ${dumpdir}/${name}/raw/preprocessing.*.log."
        utils/make_subset_data.sh "data/${name}" "${n_jobs}" "${dumpdir}/${name}/raw"
        ${train_cmd} JOB=1:${n_jobs} "${dumpdir}/${name}/raw/preprocessing.JOB.log" \
            preprocess.py \
                --config "${conf}" \
                --scp "${dumpdir}/${name}/raw/wav.JOB.scp" \
                --dumpdir "${dumpdir}/${name}/raw/dump.JOB" \
                --verbose "${verbose}"
        echo "Successfully finished feature extraction of ${name} set."
    ) &
    pids+=($!)
    done
    i=0; for pid in "${pids[@]}"; do wait "${pid}" || ((++i)); done
    [ "${i}" -gt 0 ] && echo "$0: ${i} background jobs are failed." && exit 1;
    echo "Successfully finished feature extraction."

    # calculate statistics for normalization
    echo "Statistics computation start. See the progress via ${dumpdir}/${train_set}/compute_statistics_${trg_feat}.log."
    ${train_cmd} "${dumpdir}/${train_set}/compute_statistics_${trg_feat}.log" \
        compute_statistics.py \
            --config "${conf}" \
            --rootdir "${dumpdir}/${train_set}/raw" \
            --dumpdir "${dumpdir}/${train_set}" \
            --feat_type "${trg_feat}" \
            --verbose "${verbose}"
    echo "Successfully finished calculation of statistics."

    # normalize and dump them
    pids=()
    for name in "${train_set}" "${dev_set}" "${eval_set}"; do
    (
        [ ! -e "${dumpdir}/${name}/norm" ] && mkdir -p "${dumpdir}/${name}/norm"
        echo "Nomalization start. See the progress via ${dumpdir}/${name}/norm/normalize_${trg_feat}.*.log."
        ${train_cmd} JOB=1:${n_jobs} "${dumpdir}/${name}/norm/normalize_${trg_feat}.JOB.log" \
            normalize.py \
                --config "${conf}" \
                --stats "${dumpdir}/${train_set}/stats.${stats_ext}" \
                --rootdir "${dumpdir}/${name}/raw/dump.JOB" \
                --dumpdir "${dumpdir}/${name}/norm/dump.JOB" \
                --verbose "${verbose}" \
                --feat_type "${trg_feat}" \
                --skip-wav-copy
        echo "Successfully finished normalization of ${name} set."
    ) &
    pids+=($!)
    done
    i=0; for pid in "${pids[@]}"; do wait "${pid}" || ((++i)); done
    [ "${i}" -gt 0 ] && echo "$0: ${i} background jobs are failed." && exit 1;
    echo "Successfully finished normalization."
fi

if [ "${stage}" -le 2 ] && [ "${stop_stage}" -ge 2 ]; then
    echo "Stage 2: Token list generation and tokenization"

    echo "Generate token list"
    ${train_cmd} "${token_listdir}/tokenization.log" \
        tokenize_text.py \
            --token_type "${token_type}" -f 2- \
            --input "data/${train_set}/text" --output "${token_list}" \
            --non_linguistic_symbols "${nlsyms_txt}" \
            --cleaner "${cleaner}" \
            --g2p "${g2p}" \
            --write_vocabulary true \
            --add_symbol "${blank}:0" \
            --add_symbol "${oov}:1" \
            --add_symbol "${sos_eos}:-1"
fi

if [ -z ${tag} ]; then
    expname=${token_type}_${cleaner}_$(basename ${conf%.*})
else
    expname=${token_type}_${cleaner}_${tag}
fi
expdir=exp/${expname}
if [ "${stage}" -le 3 ] && [ "${stop_stage}" -ge 3 ]; then
    echo "Stage 3: Network training"
    [ ! -e "${expdir}" ] && mkdir -p "${expdir}"
    cp "${dumpdir}/${train_set}/stats.${stats_ext}" "${expdir}/"
    cp "${token_list}" "${expdir}/tokens.txt"
    if [ "${n_gpus}" -gt 1 ]; then
        echo "Not Implemented yet."
        train="python -m seq2seq_vc.distributed.launch --nproc_per_node ${n_gpus} -c tts-train"
    else
        train="tts_train.py"
    fi
    echo "Training start. See the progress via ${expdir}/train.log."
    ${cuda_cmd} --gpu "${n_gpus}" "${expdir}/train.log" \
        ${train} \
            --config "${conf}" \
            --train-dumpdir "${dumpdir}/${train_set}/norm" \
            --dev-dumpdir "${dumpdir}/${dev_set}/norm" \
            --train-text "data/${train_set}"/text \
            --dev-text "data/${dev_set}"/text \
            --stats "${expdir}/stats.${stats_ext}" \
            --non-linguistic-symbols "${nlsyms_txt}" \
            --cleaner "${cleaner}" \
            --g2p "${g2p}" \
            --token-list "${expdir}/tokens.txt" \
            --token-type "${token_type}" \
            --feat-type "${trg_feat}" \
            --outdir "${expdir}" \
            --resume "${resume}" \
            --verbose "${verbose}"
    echo "Successfully finished training."
fi

if [ "${stage}" -le 4 ] && [ "${stop_stage}" -ge 4 ]; then
    echo "Stage 4: Network decoding"
    # shellcheck disable=SC2012
    [ -z "${checkpoint}" ] && checkpoint="$(ls -dt "${expdir}"/*.pkl | head -1 || true)"
    outdir="${expdir}/results/$(basename "${checkpoint}" .pkl)"
    pids=()
    for name in "${dev_set}" "${eval_set}"; do
        [ ! -e "${outdir}/${name}" ] && mkdir -p "${outdir}/${name}"
        [ "${n_gpus}" -gt 1 ] && n_gpus=1
        echo "Decoding start. See the progress via ${outdir}/${name}/decode.log."
        ${cuda_cmd} --gpu "${n_gpus}" "${outdir}/${name}/decode.log" \
            tts_decode.py \
                --dumpdir "${dumpdir}/${name}/norm" \
                --text "data/${name}"/text \
                --checkpoint "${checkpoint}" \
                --stats "${expdir}/stats.${stats_ext}" \
                --token-list "${expdir}/tokens.txt" \
                --feat-type "${trg_feat}" \
                --outdir "${outdir}/${name}" \
                --verbose "${verbose}"
        echo "Successfully finished decoding of ${name} set."
    done
    echo "Successfully finished decoding."
fi

if [ ${stage} -le 5 ] && [ ${stop_stage} -ge 5 ]; then
    echo "stage 5: Objective Evaluation"

    [ -z "${checkpoint}" ] && checkpoint="$(ls -dt "${expdir}"/*.pkl | head -1 || true)"
    outdir="${expdir}/results/$(basename "${checkpoint}" .pkl)"
    for name in "${dev_set}" "${eval_set}"; do
        wavdir="${outdir}/${name}/wav"
        echo "Evaluation start. See the progress via ${outdir}/${name}/evaluation.log."
        ${cuda_cmd} --gpu "${n_gpus}" "${outdir}/${name}/evaluation.log" \
            local/evaluate.py \
                --wavdir ${wavdir} \
                --data_root "${db_root}/LJSpeech-1.1" \
                --f0_path "conf/f0.yaml"
    done
fi
