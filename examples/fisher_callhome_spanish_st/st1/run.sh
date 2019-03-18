#!/bin/bash

# Copyright 2018 Kyoto University (Hirofumi Inaguma)
#  Apache 2.0  (http://www.apache.org/licenses/LICENSE-2.0)

echo ============================================================================
echo "                        Fisher Callhome Spanish                           "
echo ============================================================================

stage=0
gpu=

### path to save preproecssed data
export data=/n/sd8/inaguma/corpus/fisher_callhome_spanish

### vocabulary
# unit=wp
# vocab_size=1000
unit=char
wp_model_type=unigram  # or bpe (for wordpiece)

. ./path.sh
. ./cmd.sh

### path to save the model
model=/n/sd8/inaguma/result/fisher_callhome_spanish

### path to the model directory to restart training
rnnlm_resume_model=
resume_model=

### path to original data
sfisher_speech=/n/sd8/inaguma/corpus//fisher_callhome_spanish/links/LDC2010S01
sfisher_transcripts=/n/sd8/inaguma/corpus//fisher_callhome_spanish/links/LDC2010T04
split=local/splits/split_fisher
callhome_speech=/n/sd8/inaguma/corpus//fisher_callhome_spanish/links/LDC96S35
callhome_transcripts=/n/sd8/inaguma/corpus//fisher_callhome_spanish/links/LDC96T17
split_callhome=local/splits/split_callhome

### path to the config file
rnnlm_config=
config=

. ./cmd.sh
. ./path.sh
. utils/parse_options.sh

set -e
set -u
set -o pipefail

if [ -z ${rnnlm_config} ]; then
  rnnlm_config=conf/rnnlm/${unit}_lstm_rnnlm.yml
fi
if [ -z ${config} ]; then
  config=conf/attention/${unit}_blstm_att.yml
fi

if [ -z ${gpu} ]; then
  echo "Error: set GPU number." 1>&2
  echo "Usage: ./run.sh --gpu 0" 1>&2
  exit 1
fi
ngpus=`echo ${gpu} | tr "," "\n" | wc -l`
rnnlm_gpu=`echo ${gpu} | cut -d "," -f 1`

train_set=train.en
train_dev=dev.en
recog_set="fisher_dev.en fisher_dev2.en fisher_test.en callhome_devtest.en callhome_evltest.en"

if [ ${unit} = char ]; then
  vocab_size=
fi
if [ ${unit} != wp ]; then
  wp_model_type=
fi


if [ ${stage} -le 0 ] && [ ! -e .done_stage_0 ]; then
  echo ============================================================================
  echo "                       Data Preparation (stage:0)                          "
  echo ============================================================================

  local/fsp_data_prep.sh $sfisher_speech $sfisher_transcripts
  local/callhome_data_prep.sh $callhome_speech $callhome_transcripts

  # split data
  local/create_splits.sh $split
  local/callhome_create_splits.sh $split_callhome

  # concatenate multiple utterances
  local/normalize_trans.sh $sfisher_transcripts $callhome_transcripts

  # touch .done_stage_0 && echo "Finish data preparation (stage: 0)."
fi

exit 1

feat_tr_dir=${dumpdir}/${train_set}/delta${do_delta}; mkdir -p ${feat_tr_dir}
feat_dt_dir=${dumpdir}/${train_dev}/delta${do_delta}; mkdir -p ${feat_dt_dir}
if [ ${stage} -le 1 ]; then
    ### Task dependent. You have to design training and dev sets by yourself.
    ### But you can utilize Kaldi recipes in most cases
    echo "stage 1: Feature Generation"
    fbankdir=fbank
    # Generate the fbank features; by default 80-dimensional fbanks with pitch on each frame
    for x in fisher_train fisher_dev fisher_dev2 fisher_test callhome_train callhome_devtest callhome_evltest; do
        # upsample audio from 8k to 16k to make a recipe consistent with others
        sed -i.bak -e "s/$/ sox -R -t wav - -t wav - rate 16000 dither | /" data/${x}/wav.scp

        steps/make_fbank_pitch.sh --cmd "$train_cmd" --nj 32 --write_utt2num_frames true \
            data/${x} exp/make_fbank/${x} ${fbankdir}
    done

    # Divide into Es and En
    for x in fisher_train fisher_dev fisher_dev2 fisher_test callhome_train callhome_devtest callhome_evltest; do
        local/divide_lang.sh data/${x}
    done

    for lang in es en; do
        utils/combine_data.sh data/train.${lang} data/fisher_train.${lang} data/callhome_train.${lang}
        utils/combine_data.sh data/dev.${lang} data/fisher_dev.${lang} data/fisher_dev2.${lang} data/callhome_devtest.${lang}
    done

    for x in train dev; do
        # remove utt having more than 3000 frames
        # remove utt having more than 400 characters
        for lang in es en; do
            remove_longshortdata.sh --maxframes 3000 --maxchars 400 data/${x}.${lang} data/${x}.${lang}.tmp
        done

        # Match the number of utterances between Es and En
        # extract commocn lines
        cut -f -1 -d " " data/${x}.es.tmp/text > data/${x}.es.tmp/reclist1
        cut -f -1 -d " " data/${x}.en.tmp/text > data/${x}.es.tmp/reclist2
        comm -12 data/${x}.es.tmp/reclist1 data/${x}.es.tmp/reclist2 > data/${x}.es.tmp/reclist

        for lang in es en; do
            reduce_data_dir.sh data/${x}.${lang}.tmp data/${x}.es.tmp/reclist data/${x}.${lang}
            utils/fix_data_dir.sh data/${x}.${lang}
        done
        rm -rf data/${x}.*.tmp
    done

    # compute global CMVN
    compute-cmvn-stats scp:data/${train_set}/feats.scp data/${train_set}/cmvn.ark

    dump.sh --cmd "$train_cmd" --nj 80 --do_delta $do_delta \
        data/${train_set}/feats.scp data/${train_set}/cmvn.ark exp/dump_feats/${train_set} ${feat_tr_dir}
    dump.sh --cmd "$train_cmd" --nj 32 --do_delta $do_delta \
        data/${train_dev}/feats.scp data/${train_set}/cmvn.ark exp/dump_feats/${train_dev} ${feat_dt_dir}
    for rtask in ${recog_set}; do
        feat_recog_dir=${dumpdir}/${rtask}/delta${do_delta}; mkdir -p ${feat_recog_dir}
        dump.sh --cmd "$train_cmd" --nj 32 --do_delta $do_delta \
            data/${rtask}/feats.scp data/${train_set}/cmvn.ark exp/dump_feats/recog/${rtask} \
            ${feat_recog_dir}
    done
fi

dict=data/lang_1char/train_units.txt
nlsyms=data/lang_1char/non_lang_syms.txt
echo "dictionary: ${dict}"
if [ ${stage} -le 2 ]; then
    ### Task dependent. You have to check non-linguistic symbols used in the corpus.
    echo "stage 2: Dictionary and Json Data Preparation"
    mkdir -p data/lang_1char/

    echo "make a non-linguistic symbol list for all languages"
    cut -f 2- -d " " data/train.es/text data/train.en/text | grep -o -P '&[^;]*;' | sort | uniq > ${nlsyms}
    cat ${nlsyms}

    # Share the same dictinary between Es and En
    echo "<unk> 1" > ${dict} # <unk> must be 1, 0 will be used for "blank" in CTC
    cat data/train.es/text data/train.en/text | text2token.py -s 1 -n 1 -l ${nlsyms} | cut -f 2- -d " " | tr " " "\n" \
      | sort | uniq | grep -v -e '^\s*$' | awk '{print $0 " " NR+1}' >> ${dict}
    wc -l ${dict}

    # make json labels
    data2json.sh --feat ${feat_tr_dir}/feats.scp --nlsyms ${nlsyms} \
        data/${train_set} ${dict} > ${feat_tr_dir}/data.json
    data2json.sh --feat ${feat_dt_dir}/feats.scp --nlsyms ${nlsyms} \
        data/${train_dev} ${dict} > ${feat_dt_dir}/data.json
    for rtask in ${recog_set}; do
        feat_recog_dir=${dumpdir}/${rtask}/delta${do_delta}
        data2json.sh --feat ${feat_recog_dir}/feats.scp --nlsyms ${nlsyms} \
            data/${rtask} ${dict} > ${feat_recog_dir}/data.json
    done

    # Update json (Add En)
    for x in ${train_set} ${train_dev}; do
        feat_dir=${dumpdir}/${x}/delta${do_delta}
        data_dir=data/`echo ${x} | cut -f -1 -d "."`.es
        local/update_json.sh --nlsyms ${nlsyms} ${feat_dir}/data.json ${data_dir} ${dict}
    done

    # Fisher has 4 references per utterance
    for rtask in fisher_dev.en fisher_dev2.en fisher_test.en; do
        feat_recog_dir=${dumpdir}/${rtask}/delta${do_delta}
        for no in 1 2 3; do
          local/data2json.sh --text data/${rtask}/text.${no} --feat ${feat_recog_dir}/feats.scp --nlsyms ${nlsyms} \
              data/${rtask} ${dict} > ${feat_recog_dir}/data_${no}.json
        done
    done
fi

# You can skip this and remove --rnnlm option in the recognition (stage 3)
if [ -z ${lmtag} ]; then
    lmtag=${lm_layers}layer_unit${lm_units}_${lm_opt}_bs${lm_batchsize}
fi
lmexpdir=exp/train_rnnlm_${backend}_${lmtag}
mkdir -p ${lmexpdir}
if [ ${stage} -le 3 ]; then
    echo "stage 3: LM Preparation"
    lmdatadir=data/local/lm_${train_set}
    mkdir -p ${lmdatadir}
    text2token.py -s 1 -n 1 -l ${nlsyms} data/${train_set}/text | cut -f 2- -d " " \
        > ${lmdatadir}/train.txt
    text2token.py -s 1 -n 1 -l ${nlsyms} data/${train_dev}/text | cut -f 2- -d " " \
        > ${lmdatadir}/valid.txt
    # use only 1 gpu
    if [ ${ngpu} -gt 1 ]; then
        echo "LM training does not support multi-gpu. signle gpu will be used."
    fi
    ${cuda_cmd} --gpu ${ngpu} ${lmexpdir}/train.log \
        lm_train.py \
        --ngpu ${ngpu} \
        --backend ${backend} \
        --verbose 1 \
        --outdir ${lmexpdir} \
        --train-label ${lmdatadir}/train.txt \
        --valid-label ${lmdatadir}/valid.txt \
        --resume ${lm_resume} \
        --layer ${lm_layers} \
        --unit ${lm_units} \
        --opt ${lm_opt} \
        --batchsize ${lm_batchsize} \
        --epoch ${lm_epochs} \
        --maxlen ${lm_maxlen} \
        --dict ${dict}
fi

if [ -z ${tag} ]; then
    expdir=exp/${train_set}_${backend}_${etype}_e${elayers}_subsample${subsample}_unit${eunits}_proj${eprojs}_d${dlayers}_unit${dunits}_${atype}${adim}_aconvc${aconv_chans}_aconvf${aconv_filts}_${opt}_sampprob${samp_prob}_lsm${lsm_weight}_drop${dropout}_bs${batchsize}_mli${maxlen_in}_mlo${maxlen_out}
    if ${do_delta}; then
        expdir=${expdir}_delta
    fi
else
    expdir=exp/${train_set}_${backend}_${tag}
fi
mkdir -p ${expdir}

if [ ${stage} -le 4 ]; then
    echo "stage 4: Network Training"
    ${cuda_cmd} --gpu ${ngpu} ${expdir}/train.log \
        asr_train.py \
        --ngpu ${ngpu} \
        --backend ${backend} \
        --outdir ${expdir}/results \
        --debugmode ${debugmode} \
        --dict ${dict} \
        --debugdir ${expdir} \
        --minibatches ${N} \
        --verbose ${verbose} \
        --resume ${resume} \
        --train-json ${feat_tr_dir}/data.json \
        --valid-json ${feat_dt_dir}/data.json \
        --etype ${etype} \
        --elayers ${elayers} \
        --eunits ${eunits} \
        --eprojs ${eprojs} \
        --subsample ${subsample} \
        --dlayers ${dlayers} \
        --dunits ${dunits} \
        --atype ${atype} \
        --adim ${adim} \
        --aconv-chans ${aconv_chans} \
        --aconv-filts ${aconv_filts} \
        --mtlalpha 0 \
        --batch-size ${batchsize} \
        --maxlen-in ${maxlen_in} \
        --maxlen-out ${maxlen_out} \
        --sampling-probability ${samp_prob} \
        --lsm-type ${lsm_type} \
        --lsm-weight ${lsm_weight} \
        --dropout-rate ${dropout} \
        --opt ${opt} \
        --epochs ${epochs} \
        --eps-decay ${eps_decay}
fi

if [ ${stage} -le 5 ]; then
    echo "stage 5: Decoding"
    nj=32

    for rtask in ${recog_set}; do
    (
        decode_dir=decode_${rtask}_beam${beam_size}_e${recog_model}_p${penalty}_len${minlenratio}-${maxlenratio}_rnnlm${lm_weight}
        mkdir -p ${expdir}/${decode_dir}
        feat_recog_dir=${dumpdir}/${rtask}/delta${do_delta}

        # split data
        splitjson.py --parts ${nj} ${feat_recog_dir}/data.json

        #### use CPU for decoding
        ngpu=0

        ${decode_cmd} JOB=1:${nj} ${expdir}/${decode_dir}/log/decode.JOB.log \
            asr_recog.py \
            --ngpu ${ngpu} \
            --backend ${backend} \
            --recog-json ${feat_recog_dir}/split${nj}utt/data.JOB.json \
            --result-label ${expdir}/${decode_dir}/data.JOB.json \
            --model ${expdir}/results/${recog_model} \
            --beam-size ${beam_size} \
            --penalty ${penalty} \
            --maxlenratio ${maxlenratio} \
            --minlenratio ${minlenratio} \
            --rnnlm ${lmexpdir}/rnnlm.model.best \
            --lm-weight ${lm_weight} \
            &
        wait

        # Fisher has 4 references per utterance
        if [ ${rtask} = "fisher_dev.en" ] || [ ${rtask} = "fisher_dev2.en" ] || [ ${rtask} = "fisher_test.en"]; then
            for no in 1 2 3; do
              cp ${feat_recog_dir}/data_${no}.json ${expdir}/${decode_dir}/data_ref${no}.json
            done
        fi

        local/score_bleu.sh --set ${rtask} --nlsyms ${nlsyms} ${expdir}/${decode_dir} ${dict}

    ) &
    done
    wait
    echo "Finished"
fi
