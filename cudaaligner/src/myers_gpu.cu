/*
* Copyright (c) 2019, NVIDIA CORPORATION.  All rights reserved.
*
* NVIDIA CORPORATION and its licensors retain all intellectual property
* and proprietary rights in and to this software, related documentation
* and any modifications thereto.  Any use, reproduction, disclosure or
* distribution of this software and related documentation without an express
* license agreement from NVIDIA CORPORATION is strictly prohibited.
*/

#include "myers_gpu.cuh"
#include <cassert>
#include <climits>
#include <vector>
#include <numeric>
#include <utils/signed_integer_utils.hpp>
#include "device_storage.cuh"
#include "batched_device_matrices.cuh"
#include <cudautils/cudautils.hpp>

namespace claragenomics
{

namespace cudaaligner
{

using WordType = uint32_t;

inline __device__ WordType warp_leftshift_sync(uint32_t warp_mask, WordType v)
{
    constexpr int32_t word_size = sizeof(WordType) * CHAR_BIT;
    const WordType x            = __shfl_up_sync(warp_mask, v >> (word_size - 1), 1);
    v <<= 1;
    if (threadIdx.x != 0)
        v |= x;
    return v;
}

inline __device__ WordType warp_add_sync(uint32_t warp_mask, WordType a, WordType b)
{
    static_assert(sizeof(WordType) == 4);
    static_assert(CHAR_BIT == 8);
    const uint64_t ax = a;
    const uint64_t bx = b;
    uint64_t r        = ax + bx;
    uint32_t carry    = static_cast<uint32_t>(r >> 32);
    r &= 0xffff'ffffull;
    // TODO: I think due to the structure of the Myer blocks,
    // a carry cannot propagate over more than a single block.
    // I.e. a single carry propagation without the loop should be sufficient.
    while (__any_sync(warp_mask, carry))
    {
        uint32_t x = __shfl_up_sync(warp_mask, carry, 1);
        if (threadIdx.x != 0)
            r += x;
        carry = static_cast<uint32_t>(r >> 32);
        r &= 0xffff'ffffull;
    }
    return static_cast<WordType>(r);
}

__device__ int32_t myers_advance_block(uint32_t warp_mask, WordType highest_bit, WordType eq, WordType& pv, WordType& mv, int32_t carry_in)
{
    assert((pv & mv) == WordType(0));

    // Stage 1
    WordType xv = eq | mv;
    if (carry_in < 0)
        eq |= WordType(1);
    WordType xh = warp_add_sync(warp_mask, eq & pv, pv);
    xh          = (xh ^ pv) | eq;
    WordType ph = mv | (~(xh | pv));
    WordType mh = pv & xh;

    int32_t carry_out = ((ph & highest_bit) == WordType(0) ? 0 : 1) - ((mh & highest_bit) == WordType(0) ? 0 : 1);

    ph = warp_leftshift_sync(warp_mask, ph);
    mh = warp_leftshift_sync(warp_mask, mh);

    if (carry_in < 0)
        mh |= WordType(1);

    if (carry_in > 0)
        ph |= WordType(1);

    // Stage 2
    pv = mh | (~(xv | ph));
    mv = ph & xv;

    return carry_out;
}

__device__ WordType myers_preprocess(char x, char const* query, int32_t query_size, int32_t offset)
{
    // Sets a 1 bit at the position of every matching character
    constexpr int32_t word_size = sizeof(WordType) * CHAR_BIT;
    assert(offset < query_size);
    const int32_t max_i = min(query_size - offset, word_size);
    WordType r          = 0;
    for (int32_t i = 0; i < max_i; ++i)
    {
        if (x == query[i + offset])
            r = r | (WordType(1) << i);
    }
    return r;
}

inline __device__ int32_t get_myers_score(int32_t i, int32_t j, device_matrix_view<WordType> const& pv, device_matrix_view<WordType> const& mv, device_matrix_view<int32_t> const& score, WordType last_entry_mask)
{
    assert(i > 0); // row 0 is implicit, NW matrix is shifted by i -> i-1
    constexpr int32_t word_size = sizeof(WordType) * CHAR_BIT;
    const int32_t word_idx      = (i - 1) / word_size;
    const int32_t bit_idx       = (i - 1) % word_size;
    int32_t s                   = score(word_idx, j);
    WordType mask               = (~WordType(1)) << bit_idx;
    if (word_idx == score.num_rows() - 1)
    {
        mask &= last_entry_mask;
    }
    s -= __popc(mask & pv(word_idx, j));
    s += __popc(mask & mv(word_idx, j));
    return s;
}

__device__ void myers_backtrace(int8_t* paths_base, int32_t* lengths, device_matrix_view<WordType> const& pv, device_matrix_view<WordType> const& mv, device_matrix_view<int32_t> const& score, int32_t query_size, int32_t id)
{
    const int32_t max_path_length = 0;
    using nw_score_t              = int32_t;
    constexpr int32_t word_size   = sizeof(WordType) * CHAR_BIT;
    const int32_t n_words         = (query_size + word_size - 1) / word_size;
    assert(pv.num_rows() == score.num_rows());
    assert(mv.num_rows() == score.num_rows());
    assert(pv.num_cols() == score.num_cols());
    assert(mv.num_cols() == score.num_cols());
    assert(score.num_rows() == n_words);
    int32_t i         = query_size;
    int32_t j         = score.num_cols() - 1;
    int8_t query_ins  = 2;
    int8_t target_ins = 3;

    int8_t* path = paths_base + id * static_cast<ptrdiff_t>(max_path_length);

    const WordType last_entry_mask = query_size % word_size != 0 ? (WordType(1) << (query_size % word_size)) - 1 : ~WordType(0);

    nw_score_t myscore = score(i / word_size, j);
    int32_t pos        = 0;
    while (i > 0 && j > 0)
    {
        int8_t r               = 0;
        nw_score_t const above = get_myers_score(i - 1, j, pv, mv, score, last_entry_mask);
        nw_score_t const diag  = get_myers_score(i - 1, j - 1, pv, mv, score, last_entry_mask);
        nw_score_t const left  = get_myers_score(i, j - 1, pv, mv, score, last_entry_mask);
        if (left + 1 == myscore)
        {
            r       = query_ins;
            myscore = left;
            --j;
        }
        else if (above + 1 == myscore)
        {
            r       = target_ins;
            myscore = above;
            --i;
        }
        else
        {
            r       = (diag == myscore ? 0 : 1);
            myscore = diag;
            --i;
            --j;
        }
        path[pos] = r;
        ++pos;
    }
    while (i > 0)
    {
        path[pos] = 1;
        ++pos;
        --i;
    }
    while (j > 0)
    {
        path[pos] = 2;
        ++pos;
        --j;
    }
    lengths[id] = pos;
}

__global__ void myers_backtrace_kernel(int8_t* paths_base, int32_t* lengths, int32_t max_path_length,
                                       batched_device_matrices<WordType>::device_interface* pvi,
                                       batched_device_matrices<WordType>::device_interface* mvi,
                                       batched_device_matrices<int32_t>::device_interface* scorei,
                                       int32_t const* sequence_lengths_d,
                                       int32_t i)
{
    constexpr int32_t word_size       = sizeof(WordType) * CHAR_BIT;
    const int32_t query_size          = sequence_lengths_d[2 * i];
    const int32_t target_size         = sequence_lengths_d[2 * i + 1];
    const int32_t n_words             = (query_size + word_size - 1) / word_size;
    device_matrix_view<WordType> pv   = pvi->get_matrix_view(0, n_words, target_size + 1);
    device_matrix_view<WordType> mv   = mvi->get_matrix_view(0, n_words, target_size + 1);
    device_matrix_view<int32_t> score = scorei->get_matrix_view(0, n_words, target_size + 1);
    myers_backtrace(paths_base, lengths, pv, mv, score, query_size, i);
}

__global__ void myers_convert_to_full_score_matrix_kernel(batched_device_matrices<int32_t>::device_interface* fullscorei,
                                                          batched_device_matrices<WordType>::device_interface* pvi,
                                                          batched_device_matrices<WordType>::device_interface* mvi,
                                                          batched_device_matrices<int32_t>::device_interface* scorei,
                                                          int32_t const* sequence_lengths_d,
                                                          int32_t i)
{
    constexpr int32_t word_size           = sizeof(WordType) * CHAR_BIT;
    const int32_t query_size              = sequence_lengths_d[2 * i];
    const int32_t target_size             = sequence_lengths_d[2 * i + 1];
    const int32_t n_words                 = (query_size + word_size - 1) / word_size;
    device_matrix_view<WordType> pv       = pvi->get_matrix_view(0, n_words, target_size + 1);
    device_matrix_view<WordType> mv       = mvi->get_matrix_view(0, n_words, target_size + 1);
    device_matrix_view<int32_t> score     = scorei->get_matrix_view(0, n_words, target_size + 1);
    device_matrix_view<int32_t> fullscore = fullscorei->get_matrix_view(0, query_size + 1, target_size + 1);

    assert(query_size > 0);
    const WordType last_entry_mask = query_size % word_size != 0 ? (WordType(1) << (query_size % word_size)) - 1 : ~WordType(0);

    for (int32_t j = 0; j < target_size + 1; ++j)
    {
        fullscore(0, j) = j;
        for (int32_t i = 1; i < query_size + 1; ++i) // should be query_size + 1
        {
            fullscore(i, j) = get_myers_score(i, j, pv, mv, score, last_entry_mask);
        }
    }
}

__global__ void myers_compute_score_matrix_kernel(
    batched_device_matrices<WordType>::device_interface* pvi,
    batched_device_matrices<WordType>::device_interface* mvi,
    batched_device_matrices<int32_t>::device_interface* scorei,
    char const* sequences_d, int32_t const* sequence_lengths_d,
    int32_t max_target_query_length,
    int32_t i)
{
    constexpr int32_t word_size = sizeof(WordType) * CHAR_BIT;
    constexpr int32_t warp_size = 32;
    assert(warpSize == warp_size);
    assert(threadIdx.x < warp_size);

    const int32_t query_size  = sequence_lengths_d[2 * i];
    const int32_t target_size = sequence_lengths_d[2 * i + 1];
    const char* const query   = sequences_d + 2 * i * max_target_query_length;
    const char* const target  = sequences_d + (2 * i + 1) * max_target_query_length;
    const int32_t n_words     = (query_size + word_size - 1) / word_size;

    assert(query_size > 0);

    device_matrix_view<WordType> pv   = pvi->get_matrix_view(0, n_words, target_size + 1);
    device_matrix_view<WordType> mv   = mvi->get_matrix_view(0, n_words, target_size + 1);
    device_matrix_view<int32_t> score = scorei->get_matrix_view(0, n_words, target_size + 1);

    for (int32_t idx = threadIdx.x; idx < n_words; idx += warp_size)
    {
        pv(idx, 0)    = ~WordType(0);
        mv(idx, 0)    = 0;
        score(idx, 0) = min((idx + 1) * word_size, query_size);
    }

    for (int32_t t = 1; t <= target_size; ++t)
    {
        int32_t warp_carry = 0;
        if (threadIdx.x == 0)
            warp_carry = 1; // for global alignment the (implicit) first row has to be 0,1,2,3,... -> carry 1
        for (int32_t idx = threadIdx.x; idx < n_words; idx += warp_size)
        {
            const uint32_t warp_mask = idx / warp_size < n_words / warp_size ? 0xffff'ffffu : (1u << (n_words % warp_size)) - 1;

            WordType pv_local = pv(idx, t - 1);
            WordType mv_local = mv(idx, t - 1);
            // TODO these might be cached or only computed for the specific t at hand.
            // TODO query load is inefficient
            const WordType peq_a       = myers_preprocess('A', query, query_size, idx * word_size);
            const WordType peq_c       = myers_preprocess('C', query, query_size, idx * word_size);
            const WordType peq_g       = myers_preprocess('G', query, query_size, idx * word_size);
            const WordType peq_t       = myers_preprocess('T', query, query_size, idx * word_size);
            const WordType highest_bit = WordType(1) << (idx == (n_words - 1) ? query_size - (n_words - 1) * word_size - 1 : word_size - 1);

            const WordType eq = [peq_a, peq_c, peq_g, peq_t](char x) -> WordType {
                assert(x == 'A' || x == 'C' || x == 'G' || x == 'T');
                switch (x)
                {
                case 'A':
                    return peq_a;
                case 'C':
                    return peq_c;
                case 'G':
                    return peq_g;
                case 'T':
                    return peq_t;
                default:
                    return 0;
                }
            }(target[t - 1]);

            warp_carry    = myers_advance_block(warp_mask, highest_bit, eq, pv_local, mv_local, warp_carry);
            score(idx, t) = score(idx, t - 1) + warp_carry;
            if (threadIdx.x == 0)
                warp_carry = 0;
            //            warp_carry = __shfl_down_sync(warp_mask, warp_carry, warp_size - 1);
            if (warp_mask == 0xffff'ffffu)
                warp_carry = __shfl_down_sync(0x8000'0001u, warp_carry, warp_size - 1);
            if (threadIdx.x != 0)
                warp_carry = 0;
            pv(idx, t) = pv_local;
            mv(idx, t) = mv_local;
        }
    }
}

int32_t myers_compute_edit_distance(std::string const& target, std::string const& query)
{
    constexpr int32_t warp_size = 32;
    int32_t device_id           = 0;
    constexpr int32_t word_size = sizeof(WordType) * CHAR_BIT;
    if (get_size(query) == 0)
        return get_size(target);

    cudaStream_t stream;
    CGA_CU_CHECK_ERR(cudaStreamCreate(&stream));

    int32_t max_target_query_length = std::max(get_size(target), get_size(query));
    device_storage<char> sequences_d(2 * max_target_query_length, device_id);
    device_storage<int32_t> sequence_lengths_d(2, device_id);

    const int32_t n_words = (get_size(query) + word_size - 1) / word_size;
    batched_device_matrices<WordType> pv(1, n_words * (get_size(target) + 1), stream, device_id);
    batched_device_matrices<WordType> mv(1, n_words * (get_size(target) + 1), stream, device_id);
    batched_device_matrices<int32_t> score(1, n_words * (get_size(target) + 1), stream, device_id);

    std::array<int32_t, 2> lengths = {static_cast<int32_t>(get_size(query)), static_cast<int32_t>(get_size(target))};
    CGA_CU_CHECK_ERR(cudaMemcpyAsync(sequences_d.data(), query.data(), sizeof(char) * get_size(query), cudaMemcpyHostToDevice, stream));
    CGA_CU_CHECK_ERR(cudaMemcpyAsync(sequences_d.data() + max_target_query_length, target.data(), sizeof(char) * get_size(target), cudaMemcpyHostToDevice, stream));
    CGA_CU_CHECK_ERR(cudaMemcpyAsync(sequence_lengths_d.data(), lengths.data(), sizeof(int32_t) * 2, cudaMemcpyHostToDevice, stream));

    myers_compute_score_matrix_kernel<<<1, warp_size, 0, stream>>>(pv.get_device_interface(), mv.get_device_interface(), score.get_device_interface(), sequences_d.data(), sequence_lengths_d.data(), max_target_query_length, 0);

    matrix<int32_t> score_host = score.get_matrix(0, n_words, get_size(target) + 1, stream);
    CGA_CU_CHECK_ERR(cudaStreamSynchronize(stream));
    CGA_CU_CHECK_ERR(cudaStreamDestroy(stream));
    return score_host(n_words - 1, get_size(target));
}

matrix<int32_t> myers_get_full_score_matrix(std::string const& target, std::string const& query)
{
    constexpr int32_t warp_size = 32;
    int32_t device_id           = 0;
    constexpr int32_t word_size = sizeof(WordType) * CHAR_BIT;

    if (get_size(target) == 0)
    {
        matrix<int32_t> r(get_size(query) + 1, 1);
        std::iota(r.data(), r.data() + get_size(query) + 1, 0);
        return r;
    }
    if (get_size(query) == 0)
    {
        matrix<int32_t> r(1, get_size(target) + 1);
        std::iota(r.data(), r.data() + get_size(target) + 1, 0);
        return r;
    }

    cudaStream_t stream;
    CGA_CU_CHECK_ERR(cudaStreamCreate(&stream));

    int32_t max_target_query_length = std::max(get_size(target), get_size(query));
    device_storage<char> sequences_d(2 * max_target_query_length, device_id);
    device_storage<int32_t> sequence_lengths_d(2, device_id);

    const int32_t n_words = (get_size(query) + word_size - 1) / word_size;
    batched_device_matrices<WordType> pv(1, n_words * (get_size(target) + 1), stream, device_id);
    batched_device_matrices<WordType> mv(1, n_words * (get_size(target) + 1), stream, device_id);
    batched_device_matrices<int32_t> score(1, n_words * (get_size(target) + 1), stream, device_id);

    batched_device_matrices<int32_t> fullscore(1, (get_size(query) + 1) * (get_size(target) + 1), stream, device_id);

    std::array<int32_t, 2> lengths = {static_cast<int32_t>(get_size(query)), static_cast<int32_t>(get_size(target))};
    CGA_CU_CHECK_ERR(cudaMemcpyAsync(sequences_d.data(), query.data(), sizeof(char) * get_size(query), cudaMemcpyHostToDevice, stream));
    CGA_CU_CHECK_ERR(cudaMemcpyAsync(sequences_d.data() + max_target_query_length, target.data(), sizeof(char) * get_size(target), cudaMemcpyHostToDevice, stream));
    CGA_CU_CHECK_ERR(cudaMemcpyAsync(sequence_lengths_d.data(), lengths.data(), sizeof(int32_t) * 2, cudaMemcpyHostToDevice, stream));

    myers_compute_score_matrix_kernel<<<1, warp_size, 0, stream>>>(pv.get_device_interface(), mv.get_device_interface(), score.get_device_interface(), sequences_d.data(), sequence_lengths_d.data(), max_target_query_length, 0);
    myers_convert_to_full_score_matrix_kernel<<<1, 1, 0, stream>>>(fullscore.get_device_interface(), pv.get_device_interface(), mv.get_device_interface(), score.get_device_interface(), sequence_lengths_d.data(), 0);

    matrix<int32_t> fullscore_host = fullscore.get_matrix(0, get_size(query) + 1, get_size(target) + 1, stream);
    CGA_CU_CHECK_ERR(cudaStreamSynchronize(stream));
    CGA_CU_CHECK_ERR(cudaStreamDestroy(stream));
    return fullscore_host;
}

void myers_gpu(int8_t* paths_d, int32_t* path_lengths_d, int32_t max_path_length,
               char const* sequences_d,
               int32_t const* sequence_lengths_d,
               int32_t max_target_query_length,
               int32_t n_alignments,
               cudaStream_t stream)
{
    const int32_t device_id         = 0;
    constexpr int32_t warp_size     = 32;
    constexpr int32_t word_size     = sizeof(WordType) * CHAR_BIT;
    const int32_t max_query_length  = max_target_query_length;
    const int32_t max_target_length = max_target_query_length;
    const int32_t n_words           = (max_query_length + word_size - 1) / word_size;
    batched_device_matrices<WordType> pv(1, n_words * (max_target_length + 1), stream, device_id);
    batched_device_matrices<WordType> mv(1, n_words * (max_target_length + 1), stream, device_id);
    batched_device_matrices<int32_t> score(1, n_words * (max_target_length + 1), stream, device_id);
    for (int32_t i = 0; i < n_alignments; ++i)
    {
        myers_compute_score_matrix_kernel<<<1, warp_size, 0, stream>>>(pv.get_device_interface(), mv.get_device_interface(), score.get_device_interface(), sequences_d, sequence_lengths_d, max_target_query_length, i);
        myers_backtrace_kernel<<<1, 1, 0, stream>>>(paths_d, path_lengths_d, max_path_length, pv.get_device_interface(), mv.get_device_interface(), score.get_device_interface(), sequence_lengths_d, i);
    }
    CGA_CU_CHECK_ERR(cudaStreamSynchronize(stream));
}

} // namespace cudaaligner
} // namespace claragenomics
