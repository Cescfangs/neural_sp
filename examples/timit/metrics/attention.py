#! /usr/bin/env python
# -*- coding: utf-8 -*-

"""Define evaluation method for the Attention-based model (TIMIT corpus)."""

from __future__ import absolute_import
from __future__ import division
from __future__ import print_function

from tqdm import tqdm

from examples.timit.metrics.mapping import Map2phone39
from utils.io.labels.phone import Idx2phone
from utils.io.variable import np2var_pytorch
from utils.evaluation.edit_distance import compute_per


def do_eval_per(model, dataset, label_type, beam_width,
                is_test=False, eval_batch_size=None, progressbar=False):
    """Evaluate trained model by Phone Error Rate.
    Args:
        model: the model to evaluate
        dataset: An instance of a `Dataset' class
        label_type (string): phone39 or phone48 or phone61
        beam_width: (int): the size of beam
        is_test (bool, optional): set to True when evaluating by the test set
        eval_batch_size (int, optional): the batch size when evaluating the model
        progressbar (bool, optional): if True, visualize the progressbar
    Returns:
        per_mean (float): An average of PER
    """
    batch_size_original = dataset.batch_size

    # Reset data counter
    dataset.reset()

    # Set batch size in the evaluation
    if eval_batch_size is not None:
        dataset.batch_size = eval_batch_size

    train_label_type = label_type
    eval_label_type = dataset.label_type

    idx2phone_train = Idx2phone(
        map_file_path='../metrics/mapping_files/' + train_label_type + '.txt')
    idx2phone_eval = Idx2phone(
        map_file_path='../metrics/mapping_files/' + eval_label_type + '.txt')
    map2phone39_train = Map2phone39(
        label_type=train_label_type,
        map_file_path='../metrics/mapping_files/phone2phone.txt')
    map2phone39_eval = Map2phone39(
        label_type=eval_label_type,
        map_file_path='../metrics/mapping_files/phone2phone.txt')

    per_mean = 0
    if progressbar:
        pbar = tqdm(total=len(dataset))
    for data, is_new_epoch in dataset:

        # Create feed dictionary for next mini-batch
        inputs, labels_true, _, labels_seq_len, _ = data
        inputs = np2var_pytorch(inputs, volatile=True)
        if model.use_cuda:
            inputs = inputs.cuda()

        batch_size = inputs[0].size()[0]

        # Evaluate by 39 phones
        labels_pred, _ = model.decode_infer(
            inputs[0], beam_width=beam_width)

        for i_batch in range(batch_size):
            ###############
            # Hypothesis
            ###############
            # Convert from index to phone (-> list of phone strings)
            str_pred = idx2phone_train(labels_pred[i_batch]).split('>')[0]
            # NOTE: Trancate by <EOS>

            # Remove the last space
            if len(str_pred) > 0 and str_pred[-1] == ' ':
                str_pred = str_pred[:-1]

            phone_pred_list = str_pred.split(' ')

            ###############
            # Reference
            ###############
            if is_test:
                phone_true_list = labels_true[0][i_batch][0].split(' ')
            else:
                # Convert from index to phone (-> list of phone strings)
                phone_true_list = idx2phone_eval(
                    labels_true[0][i_batch][1:labels_seq_len[0][i_batch] - 1]).split(' ')
                # NOTE: Exclude <SOS> and <EOS>

            # Mapping to 39 phones (-> list of phone strings)
            phone_pred_list = map2phone39_train(phone_pred_list)
            phone_true_list = map2phone39_eval(phone_true_list)

            # Compute PER
            per_mean += compute_per(ref=phone_pred_list,
                                    hyp=phone_true_list,
                                    normalize=True)

            if progressbar:
                pbar.update(1)

        if is_new_epoch:
            break

    per_mean /= len(dataset)

    # Register original batch size
    if eval_batch_size is not None:
        dataset.batch_size = batch_size_original

    return per_mean
