#include <iostream>
#include <cassert>
#include <type_traits>
#include <cublas.h>
#include <cutf/cuda.hpp>
#include <cumpsgemm/cumpsgemm.hpp>

#include "handle.hpp"
#include "exp_stats.hpp"

// For debug
//#define CUMPSGEMM_CHECK_KERNEL_ERROR

namespace {
template <class T>
cumpsgemm::kernel_module_code::code_t gen_module_code(
		const cublasOperation_t op_A,
		const cublasOperation_t op_B,
		const cuMpSGEMM_compute_mode_t compute_mode
		) {
	cumpsgemm::kernel_module_code::code_t code = 0;
	switch (compute_mode) {
	case CUMPSGEMM_FP16TC:   code |= cumpsgemm::kernel_module_code::half | cumpsgemm::kernel_module_code::without_ec;break;
	case CUMPSGEMM_FP16TCEC: code |= cumpsgemm::kernel_module_code::half | cumpsgemm::kernel_module_code::with_ec   ;break;
	case CUMPSGEMM_TF32TC:   code |= cumpsgemm::kernel_module_code::tf32 | cumpsgemm::kernel_module_code::without_ec;break;
	case CUMPSGEMM_TF32TCEC: code |= cumpsgemm::kernel_module_code::tf32 | cumpsgemm::kernel_module_code::with_ec   ;break;
	default:break;
	}
	switch (op_A) {
	case CUBLAS_OP_N: code |= cumpsgemm::kernel_module_code::op_a_col_major;break;
	case CUBLAS_OP_T: code |= cumpsgemm::kernel_module_code::op_a_row_major;break;
	case CUBLAS_OP_C: code |= cumpsgemm::kernel_module_code::op_a_conjugate;break;
	default:break;
	}
	switch (op_B) {
	case CUBLAS_OP_N: code |= cumpsgemm::kernel_module_code::op_b_col_major;break;
	case CUBLAS_OP_T: code |= cumpsgemm::kernel_module_code::op_b_row_major;break;
	case CUBLAS_OP_C: code |= cumpsgemm::kernel_module_code::op_b_conjugate;break;
	default:break;
	}
	if (std::is_same<T, float>::value) {
		code |= cumpsgemm::kernel_module_code::s;
	} else if (std::is_same<T, cuComplex>::value) {
		code |= cumpsgemm::kernel_module_code::c;
	}

	assert(code <= cumpsgemm::kernel_module_code::max_code);

	return code;
}

template <class T>
void launch_kernel (
			const cumpsgemm::gemm_module gemm_module,
			const std::size_t m,
			const std::size_t n,
			const std::size_t k,
			const T alpha,
			const T* const a_ptr, const std::size_t lda,
			const T* const b_ptr, const std::size_t ldb,
			const T beta,
			T* const c_ptr, const std::size_t ldc,
			const typename cumpsgemm::device::element_t_conv<T>::type ignore_threshold,
			const typename cumpsgemm::device::element_t_conv<T>::type lost_threshold,
			cumpsgemm::counter_t* const total_counter,
			cumpsgemm::counter_t* const lost_counter,
			cudaStream_t cuda_stream
		) {
	const auto kernel_ptr = reinterpret_cast<cumpsgemm::gemm_kernel_func_t<T>>(gemm_module.kernel_func);
	const dim3 block_size(gemm_module.block_size);
	const dim3 grid_size(
			((m + gemm_module.smem_m - 1) / gemm_module.smem_m) * ((n + gemm_module.smem_n - 1) / gemm_module.smem_n)
			);

	kernel_ptr<<<grid_size, block_size, gemm_module.smem_size, cuda_stream>>>(
			m, n, k,
			alpha,
			a_ptr, lda,
			b_ptr, ldb,
			beta,
			c_ptr, ldc,
			ignore_threshold, lost_threshold,
			total_counter, lost_counter
			);
#ifdef CUMPSGEMM_CHECK_KERNEL_ERROR
	CUTF_CHECK_ERROR(cudaStreamSynchronize(cuda_stream));
#endif
}

template <class T>
void launch_kernel (
			const cumpsgemm::gemm_module gemm_module,
			const std::size_t m,
			const std::size_t n,
			const std::size_t k,
			const T alpha,
			const T* const a_ptr, const std::size_t lda, const uint64_t stridea,
			const T* const b_ptr, const std::size_t ldb, const uint64_t strideb,
			const T beta,
			T* const c_ptr, const std::size_t ldc, const uint64_t stridec,
			const uint64_t batch_count,
			const typename cumpsgemm::device::element_t_conv<T>::type ignore_threshold,
			const typename cumpsgemm::device::element_t_conv<T>::type lost_threshold,
			cumpsgemm::counter_t* const total_counter,
			cumpsgemm::counter_t* const lost_counter,
			cudaStream_t cuda_stream
		) {
	const auto kernel_ptr = reinterpret_cast<cumpsgemm::gemm_stridedBatch_kernel_func_t<T>>(gemm_module.kernel_func);
	const dim3 block_size(gemm_module.block_size);
	const auto num_blocks_per_gemm = (m + gemm_module.smem_m - 1) / gemm_module.smem_m * (n + gemm_module.smem_n - 1) / gemm_module.smem_n;
	const dim3 grid_size(
			num_blocks_per_gemm * batch_count
			);

	kernel_ptr<<<grid_size, block_size, gemm_module.smem_size, cuda_stream>>>(
			m, n, k,
			alpha,
			a_ptr, lda, stridea,
			b_ptr, ldb, strideb,
			beta,
			c_ptr, ldc, stridec,
			num_blocks_per_gemm,
			ignore_threshold, lost_threshold,
			total_counter, lost_counter
			);
#ifdef CUMPSGEMM_CHECK_KERNEL_ERROR
	CUTF_CHECK_ERROR(cudaStreamSynchronize(cuda_stream));
#endif
}
} // unnamed namespace

template <class T>
cublasStatus_t cumpsgemm::gemm(
		cuMpSGEMM_handle_t handle,
		const cublasOperation_t op_A,
		const cublasOperation_t op_B,
		const uint64_t m,
		const uint64_t n,
		const uint64_t k,
		const T* alpha,
		const T* const a_dmem_ptr, const uint64_t lda,
		const T* const b_dmem_ptr, const uint64_t ldb,
		const T* beta,
		T* const c_dmem_ptr, const uint64_t ldc,
		const cuMpSGEMM_compute_mode_t compute_mode,
		unsigned* const used_kernel_modeule_id
		) {
	const auto code = gen_module_code<T>(op_A, op_B, compute_mode);

	const auto kernel_module_candidate_list = handle->gemm_module[code];

	unsigned module_id;
	auto gemm_module = kernel_module_candidate_list[handle->num_kernel_candidates - 1];
	for (module_id = 0; module_id < handle->num_kernel_candidates - 1; module_id++) {
		const auto module = kernel_module_candidate_list[module_id];
		if (m * n / (module.smem_m * module.smem_n) > handle->num_sms * 32 /*A magic number :) */) {
			gemm_module = module;
			break;
		}
	}

	if (used_kernel_modeule_id != nullptr) {
		*used_kernel_modeule_id = module_id;
	}

	cumpsgemm::counter_t* total_counter_ptr  = nullptr;
	cumpsgemm::counter_t* lost_counter_ptr = nullptr;
	if (handle->exp_stats_enabled) {
		if (!(handle->counter_init_disabled)) {
			cumpsgemm::exp_stats::get_next_buffer_id(handle);
		}
		const auto buffer_id = cumpsgemm::exp_stats::get_current_buffer_id(handle);
		if (!(handle->counter_init_disabled)) {
			cumpsgemm::exp_stats::init_counter(
					handle,
					buffer_id
					);
		}
		total_counter_ptr = handle->dev_total_counter_buffer + buffer_id;
		lost_counter_ptr  = handle->dev_lost_counter_buffer  + buffer_id;
	}

	launch_kernel<T>(
			gemm_module,
			m, n, k,
			*alpha,
			a_dmem_ptr, lda,
			b_dmem_ptr, ldb,
			*beta,
			c_dmem_ptr, ldc,
			handle->ignore_threshold,
			handle->lost_threshold,
			total_counter_ptr,
			lost_counter_ptr,
			handle->cuda_stream
			);


	if (handle->exp_stats_enabled) {
		const auto buffer_id = cumpsgemm::exp_stats::get_current_buffer_id(handle);
		cumpsgemm::exp_stats::download_exp_stats(handle, buffer_id);
	}
	return CUBLAS_STATUS_SUCCESS;
}


template <class T>
cublasStatus_t cumpsgemm::gemm_stridedBatch(
		cuMpSGEMM_handle_t handle,
		const cublasOperation_t op_A,
		const cublasOperation_t op_B,
		const uint64_t m,
		const uint64_t n,
		const uint64_t k,
		const T* alpha,
		const T* const a_dmem_ptr, const uint64_t lda, const uint64_t stridea,
		const T* const b_dmem_ptr, const uint64_t ldb, const uint64_t strideb,
		const T* beta,
		T* const c_dmem_ptr, const uint64_t ldc, const uint64_t stridec,
		const uint64_t batch_count,
		const cuMpSGEMM_compute_mode_t compute_mode,
		unsigned* const used_kernel_modeule_id
		) {
	const auto code = gen_module_code<T>(op_A, op_B, compute_mode);

	const auto kernel_module_candidate_list = handle->gemm_stridedBatch_module[code];

	if (m * n > (1lu << 24)) {
		for (std::uint64_t i = 0; i < batch_count; i++) {
			cumpsgemm::gemm(
					handle,
					op_A, op_B,
					m, n, k,
					alpha,
					a_dmem_ptr + i * stridea, lda,
					b_dmem_ptr + i * strideb, ldb,
					beta,
					c_dmem_ptr + i * stridec, ldc,
					compute_mode,
					used_kernel_modeule_id
					);
			handle->counter_init_disabled = true;
		}
		handle->counter_init_disabled = false;
		return CUBLAS_STATUS_SUCCESS;
	}

	unsigned module_id;
	auto gemm_module = kernel_module_candidate_list[handle->num_kernel_candidates - 1];
	for (module_id = 0; module_id < handle->num_kernel_candidates - 1; module_id++) {
		const auto module = kernel_module_candidate_list[module_id];
		if (m * n / (module.smem_m * module.smem_n) * batch_count > handle->num_sms * 32 /*A magic number :) */) {
			gemm_module = module;
			break;
		}
	}

	if (used_kernel_modeule_id != nullptr) {
		*used_kernel_modeule_id = module_id;
	}

	cumpsgemm::counter_t* total_counter_ptr  = nullptr;
	cumpsgemm::counter_t* lost_counter_ptr = nullptr;
	if (handle->exp_stats_enabled) {
		cumpsgemm::exp_stats::get_next_buffer_id(handle);
		const auto buffer_id = cumpsgemm::exp_stats::get_current_buffer_id(handle);
		cumpsgemm::exp_stats::init_counter(
				handle,
				buffer_id
				);
		total_counter_ptr = handle->dev_total_counter_buffer + buffer_id;
		lost_counter_ptr  = handle->dev_lost_counter_buffer  + buffer_id;
	}

	launch_kernel<T>(
			gemm_module,
			m, n, k,
			*alpha,
			a_dmem_ptr, lda, stridea,
			b_dmem_ptr, ldb, strideb,
			*beta,
			c_dmem_ptr, ldc, stridec,
			batch_count,
			handle->ignore_threshold,
			handle->lost_threshold,
			total_counter_ptr,
			lost_counter_ptr,
			handle->cuda_stream
			);

	if (handle->exp_stats_enabled) {
		const auto buffer_id = cumpsgemm::exp_stats::get_current_buffer_id(handle);
		cumpsgemm::exp_stats::download_exp_stats(handle, buffer_id);
	}

	return CUBLAS_STATUS_SUCCESS;
}

extern "C" {
cublasStatus_t cuMpSGEMM_sgemm(
		cuMpSGEMM_handle_t handle,
		const cublasOperation_t op_A,
		const cublasOperation_t op_B,
		const uint64_t m,
		const uint64_t n,
		const uint64_t k,
		const float* alpha,
		const float* const a_dmem_ptr, const uint64_t lda,
		const float* const b_dmem_ptr, const uint64_t ldb,
		const float* beta,
		float* const c_dmem_ptr, const uint64_t ldc,
		const cuMpSGEMM_compute_mode_t compute_mode
		) {
	assert(op_A != CUBLAS_OP_C);
	assert(op_B != CUBLAS_OP_C);
	return cumpsgemm::gemm<float>(
			handle,
			op_A, op_B,
			m, n, k,
			alpha,
			a_dmem_ptr, lda,
			b_dmem_ptr, ldb,
			beta,
			c_dmem_ptr, ldc,
			compute_mode
			);
}

cublasStatus_t cuMpSGEMM_cgemm(
		cuMpSGEMM_handle_t handle,
		const cublasOperation_t op_A,
		const cublasOperation_t op_B,
		const uint64_t m,
		const uint64_t n,
		const uint64_t k,
		const cuComplex* alpha,
		const cuComplex* const a_dmem_ptr, const uint64_t lda,
		const cuComplex* const b_dmem_ptr, const uint64_t ldb,
		const cuComplex* beta,
		cuComplex* const c_dmem_ptr, const uint64_t ldc,
		const cuMpSGEMM_compute_mode_t compute_mode
		) {
	return cumpsgemm::gemm<cuComplex>(
			handle,
			op_A, op_B,
			m, n, k,
			alpha,
			a_dmem_ptr, lda,
			b_dmem_ptr, ldb,
			beta,
			c_dmem_ptr, ldc,
			compute_mode
			);
}

cublasStatus_t cuMpSGEMM_sgemm_strided_batch(
		cuMpSGEMM_handle_t handle,
		const cublasOperation_t op_A,
		const cublasOperation_t op_B,
		const uint64_t m,
		const uint64_t n,
		const uint64_t k,
		const float* alpha,
		const float* const a_dmem_ptr, const uint64_t lda, const uint64_t stridea,
		const float* const b_dmem_ptr, const uint64_t ldb, const uint64_t strideb,
		const float* beta,
		float* const c_dmem_ptr, const uint64_t ldc, const uint64_t stridec,
		const uint64_t batch_count,
		const cuMpSGEMM_compute_mode_t compute_mode
		) {
	assert(op_A != CUBLAS_OP_C);
	assert(op_B != CUBLAS_OP_C);
	return cumpsgemm::gemm_stridedBatch<float>(
			handle,
			op_A, op_B,
			m, n, k,
			alpha,
			a_dmem_ptr, lda, stridea,
			b_dmem_ptr, ldb, strideb,
			beta,
			c_dmem_ptr, ldc, stridec,
			batch_count,
			compute_mode
			);
}

cublasStatus_t cuMpSGEMM_cgemm_strided_batch(
		cuMpSGEMM_handle_t handle,
		const cublasOperation_t op_A,
		const cublasOperation_t op_B,
		const uint64_t m,
		const uint64_t n,
		const uint64_t k,
		const cuComplex* alpha,
		const cuComplex* const a_dmem_ptr, const uint64_t lda, const uint64_t stridea,
		const cuComplex* const b_dmem_ptr, const uint64_t ldb, const uint64_t strideb,
		const cuComplex* beta,
		cuComplex* const c_dmem_ptr, const uint64_t ldc, const uint64_t stridec,
		const uint64_t batch_count,
		const cuMpSGEMM_compute_mode_t compute_mode
		) {
	return cumpsgemm::gemm_stridedBatch<cuComplex>(
			handle,
			op_A, op_B,
			m, n, k,
			alpha,
			a_dmem_ptr, lda, stridea,
			b_dmem_ptr, ldb, strideb,
			beta,
			c_dmem_ptr, ldc, stridec,
			batch_count,
			compute_mode
			);
}

} // extern "C"

std::pair<std::size_t, std::size_t> cumpsgemm::get_exp_stats(
		cuMpSGEMM_handle_t handle,
		const unsigned buffer_id
		) {
	return cumpsgemm::exp_stats::get_exp_stats(handle, buffer_id);
}

unsigned cumpsgemm::get_current_buffer_id(
		cuMpSGEMM_handle_t handle
		) {
	return cumpsgemm::exp_stats::get_current_buffer_id(handle);
}
