#include <iostream>
#include <vector>
#include <string>
#include <fstream>
#include <chrono>
#include <regex>
#include <cutf/curand.hpp>
#include <cutf/memory.hpp>
#include <cutf/cublas.hpp>
#include <cumpsgemm/cumpsgemm.hpp>

constexpr unsigned test_count = 32;

enum gemm_type {
	s, c
};

double error_threshold(
		const cuMpSGEMM_compute_mode_t compute_mode,
		const std::size_t N
		) {
	if (compute_mode == CUMPSGEMM_FP16TC ||
			compute_mode == CUMPSGEMM_TF32TC) {
		return 1. / (1 << 10) * std::sqrt(N);
	}
	return 1. / (1 << 23) * std::sqrt(N);
}

__device__ double mad(
		const float a,
		const float b,
		const double c
		) {
	return static_cast<double>(a) * static_cast<double>(b) + c;
}

__device__ double2 mad(
		const float2 a,
		const float2 b,
		const double2 c
		) {
	const auto dbl_a = cuComplexFloatToDouble(a);
	const auto dbl_b = cuComplexFloatToDouble(b);
	return cuCadd(cuCmul(dbl_a, dbl_b), c);
}

template <class T>
struct doubled_t {using type = double;};
template <> struct doubled_t<cuComplex> {using type = cuDoubleComplex;};

template <class T>
__device__ T load_with_op(
		const T* const ptr,
		cublasOperation_t op
		) {
	return *ptr;
}

template <>
__device__ cuComplex load_with_op<cuComplex>(
		const cuComplex* const ptr,
		cublasOperation_t op
		) {
	if (op == CUBLAS_OP_C) {
		const auto v = *ptr;
		return cuConjf(v);
	}
	return *ptr;
}

__device__ double diff2(
		const cuDoubleComplex ab,
		const cuComplex c
		) {
	const auto real_diff = ab.x - c.x;
	const auto imag_diff = ab.y - c.y;
	return real_diff * real_diff + imag_diff * imag_diff;
}
__device__ double diff2(
		const double ab,
		const float c
		) {
	const auto diff = ab - c;
	return diff * diff;
}
__device__ double norm2(
		const cuDoubleComplex a
		) {
	return a.x * a.x + a.y * a.y;
}
__device__ double norm2(
		const double a
		) {
	return a * a;
}


template <class T>
__host__ __device__ T one() {return 1;}
template <> __host__ __device__ cuComplex one() {return make_cuComplex(1, 0);}
template <class T>
__host__ __device__ T zero() {return 0;}
template <> __host__ __device__ cuComplex zero() {return make_cuComplex(0, 0);}
template <> __host__ __device__ cuDoubleComplex zero() {return make_cuDoubleComplex(0, 0);}


template <class T>
__global__ void calc_matmul_residual_kernel(
		double* const base_norm2_ptr,
		double* const diff_norm2_ptr,
		const cublasOperation_t op_A,
		const cublasOperation_t op_B,
		const unsigned m,
		const unsigned n,
		const unsigned k,
		const T* const a_ptr, const unsigned lda,
		const T* const b_ptr, const unsigned ldb,
		const T* const c_ptr, const unsigned ldc
		) {
	const auto tid = blockDim.x * blockIdx.x + threadIdx.x;
	if (tid >= m * n) return;

	const auto c_m = tid % m;
	const auto c_n = tid / m;

	auto c = zero<typename doubled_t<T>::type>();
	for (std::size_t ik = 0; ik < k; ik++) {
		std::size_t a_index = 0;
		if (op_A == CUBLAS_OP_N) {
			a_index = c_m + ik * lda;
		} else {
			a_index = ik + c_m * lda;
		}

		std::size_t b_index = 0;
		if (op_B == CUBLAS_OP_N) {
			b_index = ik + c_n * ldb;
		} else {
			b_index = c_n + ik * ldb;
		}

		c = mad(
				load_with_op(a_ptr + a_index, op_A),
				load_with_op(b_ptr + b_index, op_B),
				c
				);
		const auto aa = load_with_op(a_ptr + a_index, op_A);
		const auto bb = load_with_op(b_ptr + b_index, op_B);
	}
	const auto base_norm2 = norm2(c);
	const auto diff_norm2 = diff2(c, c_ptr[c_m + c_n * ldc]);

	atomicAdd(base_norm2_ptr, base_norm2);
	atomicAdd(diff_norm2_ptr, diff_norm2);
}

template <class T>
double calc_matmul_residual(
		const cublasOperation_t op_A,
		const cublasOperation_t op_B,
		const unsigned m,
		const unsigned n,
		const unsigned k,
		const T* const a_ptr, const unsigned lda,
		const T* const b_ptr, const unsigned ldb,
		const T* const c_ptr, const unsigned ldc
		) {
	auto base_norm2_ptr = cutf::memory::malloc_managed<double>(1);
	auto diff_norm2_ptr = cutf::memory::malloc_managed<double>(1);

	*base_norm2_ptr = 0;
	*diff_norm2_ptr = 0;

	constexpr unsigned block_size = 256;
	const auto num_threads = m * n;
	const auto grid_size = (num_threads + block_size - 1) / block_size;

	cudaDeviceSynchronize();
	calc_matmul_residual_kernel<<<grid_size, block_size>>>(
			base_norm2_ptr, diff_norm2_ptr,
			op_A, op_B,
			m, n, k,
			a_ptr, lda,
			b_ptr, ldb,
			c_ptr, ldc
			);
	cudaDeviceSynchronize();

	const auto residual = std::sqrt(*diff_norm2_ptr / *base_norm2_ptr);

	cutf::memory::free(base_norm2_ptr);
	cutf::memory::free(diff_norm2_ptr);

	return residual;
}

void cublas_gemm(
		cublasHandle_t const cublas_handle,
		const cublasOperation_t op_A,
		const cublasOperation_t op_B,
		const unsigned m,
		const unsigned n,
		const unsigned k,
		const float* const alpha,
		const float* const a_ptr, const unsigned lda,
		const float* const b_ptr, const unsigned ldb,
		const float* const beta,
		float* const c_ptr, const unsigned ldc
		) {
		CUTF_CHECK_ERROR(cublasSgemm(
					cublas_handle,
					op_A, op_B,
					m, n, k,
					alpha,
					a_ptr, lda,
					b_ptr, ldb,
					beta,
					c_ptr, ldc
					));
}

void cublas_gemm(
		cublasHandle_t const cublas_handle,
		const cublasOperation_t op_A,
		const cublasOperation_t op_B,
		const unsigned m,
		const unsigned n,
		const unsigned k,
		const cuComplex* const alpha,
		const cuComplex* const a_ptr, const unsigned lda,
		const cuComplex* const b_ptr, const unsigned ldb,
		const cuComplex* const beta,
		cuComplex* const c_ptr, const unsigned ldc
		) {
		CUTF_CHECK_ERROR(cublasCgemm(
					cublas_handle,
					op_A, op_B,
					m, n, k,
					alpha,
					a_ptr, lda,
					b_ptr, ldb,
					beta,
					c_ptr, ldc
					));
}

void cublas_gemm_strided_batch(
		cublasHandle_t const cublas_handle,
		const cublasOperation_t op_A,
		const cublasOperation_t op_B,
		const unsigned m,
		const unsigned n,
		const unsigned k,
		const float* const alpha,
		const float* const a_ptr, const unsigned lda, const long long int stride_a,
		const float* const b_ptr, const unsigned ldb, const long long int stride_b,
		const float* const beta,
		float* const c_ptr, const unsigned ldc, const long long int stride_c,
		const long long int batch_count
		) {
		CUTF_CHECK_ERROR(cublasSgemmStridedBatched(
					cublas_handle,
					op_A, op_B,
					m, n, k,
					alpha,
					a_ptr, lda, stride_a,
					b_ptr, ldb, stride_b,
					beta,
					c_ptr, ldc, stride_c,
					batch_count
					));
}

void cublas_gemm_strided_batch(
		cublasHandle_t const cublas_handle,
		const cublasOperation_t op_A,
		const cublasOperation_t op_B,
		const unsigned m,
		const unsigned n,
		const unsigned k,
		const cuComplex* const alpha,
		const cuComplex* const a_ptr, const unsigned lda, const long long int stride_a,
		const cuComplex* const b_ptr, const unsigned ldb, const long long int stride_b,
		const cuComplex* const beta,
		cuComplex* const c_ptr, const unsigned ldc, const long long int stride_c,
		const long long int batch_count
		) {
		CUTF_CHECK_ERROR(cublasCgemmStridedBatched(
					cublas_handle,
					op_A, op_B,
					m, n, k,
					alpha,
					a_ptr, lda, stride_a,
					b_ptr, ldb, stride_b,
					beta,
					c_ptr, ldc, stride_c,
					batch_count
					));
}

template <class T>
int sgemm_test_core(
		cublasHandle_t const cublas_handle,
		cuMpSGEMM_handle_t const cuMpSGEMM_handle,
		const cublasOperation_t op_A,
		const cublasOperation_t op_B,
		const unsigned m,
		const unsigned n,
		const unsigned k,
		T* const a_ptr, const unsigned lda,
		T* const b_ptr, const unsigned ldb,
		T* const c_ptr, const unsigned ldc,
		const cuMpSGEMM_compute_mode_t compute_mode
		) {
	const auto alpha = one<T>(), beta = zero<T>();

	unsigned module_stage = 0;
	auto gemm_func = [&]() {
		if (compute_mode == CUMPSGEMM_CUBLAS) {
			cublas_gemm(
					cublas_handle,
					op_A, op_B,
					m, n, k,
					&alpha,
					a_ptr, lda,
					b_ptr, ldb,
					&beta,
					c_ptr, ldc
					);
		} else {
			cumpsgemm::gemm(
					cuMpSGEMM_handle,
					op_A, op_B,
					m, n, k,
					&alpha,
					a_ptr, lda,
					b_ptr, ldb,
					&beta,
					c_ptr, ldc,
					compute_mode,
					&module_stage
					);
		}
	};

	gemm_func();

	CUTF_CHECK_ERROR(cudaDeviceSynchronize());

	const auto residual = calc_matmul_residual(
					op_A, op_B,
					m, n, k,
					a_ptr, lda,
					b_ptr, ldb,
					c_ptr, ldc
			);
	const auto check = residual < error_threshold(compute_mode, k);

	// Throughput
	CUTF_CHECK_ERROR(cudaDeviceSynchronize());
	const auto start_clock = std::chrono::system_clock::now();
	for (unsigned i = 0; i < test_count; i++) {
		gemm_func();
	}
	CUTF_CHECK_ERROR(cudaDeviceSynchronize());
	const auto end_clock = std::chrono::system_clock::now();
	const auto elapsed_time = std::chrono::duration_cast<std::chrono::microseconds>(end_clock - start_clock).count() * 1e-6;
	const auto throughput = 2lu * m * n * k * (std::is_same<float, T>::value ? 1 : 4) / (elapsed_time / test_count);

	std::printf("%s,%s,%s,%s,%u,%u,%u,%e,%e,%s,%u\n",
			(std::is_same<float, T>::value ? "sgemm" : "cgemm"),
			cuMpSGEMM_get_compute_mode_string(compute_mode),
			(op_A == CUBLAS_OP_N) ? "N" : ((op_A == CUBLAS_OP_T) ? "T" : "C"),
			(op_B == CUBLAS_OP_N) ? "N" : ((op_B == CUBLAS_OP_T) ? "T" : "C"),
			m, n, k,
			throughput * 1e-12,
			residual,
			(check ? "OK" : "NG"),
			module_stage
			);
	std::fflush(stdout);

	if (check) {
		return 0;
	} else {
		return 1;
	}
}

template <class T>
int sgemm_strided_batch_test_core(
		cublasHandle_t const cublas_handle,
		cuMpSGEMM_handle_t const cuMpSGEMM_handle,
		const cublasOperation_t op_A,
		const cublasOperation_t op_B,
		const unsigned m,
		const unsigned n,
		const unsigned k,
		T* const a_ptr, const unsigned lda, const long long int stride_a,
		T* const b_ptr, const unsigned ldb, const long long int stride_b,
		T* const c_ptr, const unsigned ldc, const long long int stride_c,
		const long long int batch_count,
		const cuMpSGEMM_compute_mode_t compute_mode
		) {
	const auto alpha = one<T>(), beta = zero<T>();

	unsigned module_stage = 0;

	auto gemm_func = [&]() {
		if (compute_mode == CUMPSGEMM_CUBLAS) {
			cublas_gemm_strided_batch(
					cublas_handle,
					op_A, op_B,
					m, n, k,
					&alpha,
					a_ptr, lda, stride_a,
					b_ptr, ldb, stride_b,
					&beta,
					c_ptr, ldc, stride_c,
					batch_count
					);
		} else {
			cumpsgemm::gemm_stridedBatch(
					cuMpSGEMM_handle,
					op_A, op_B,
					m, n, k,
					&alpha,
					a_ptr, lda, stride_a,
					b_ptr, ldb, stride_b,
					&beta,
					c_ptr, ldc, stride_c,
					batch_count,
					compute_mode,
					&module_stage
					);
		}
	};

	gemm_func();

	CUTF_CHECK_ERROR(cudaDeviceSynchronize());

	double residual = 0;
	for (unsigned long long int b = 0; b < batch_count; b++) {
	 	residual += calc_matmul_residual(
					op_A, op_B,
					m, n, k,
					a_ptr + stride_a * b, lda,
					b_ptr + stride_b * b, ldb,
					c_ptr + stride_c * b, ldc
			);
	}
	residual /= batch_count;
	const auto check = residual < error_threshold(compute_mode, m);

	// Throughput
	CUTF_CHECK_ERROR(cudaDeviceSynchronize());
	const auto start_clock = std::chrono::system_clock::now();
	for (unsigned i = 0; i < test_count; i++) {
		gemm_func();
	}
	CUTF_CHECK_ERROR(cudaDeviceSynchronize());
	const auto end_clock = std::chrono::system_clock::now();
	const auto elapsed_time = std::chrono::duration_cast<std::chrono::microseconds>(end_clock - start_clock).count() * 1e-6;
	const auto throughput = 2lu * m * n * k * batch_count * (std::is_same<float, T>::value ? 1 : 4) / (elapsed_time / test_count);

	std::printf("%s,%s,%s,%s,%u,%u,%u,%lld,%e,%e,%s,%u\n",
			(std::is_same<float, T>::value ? "sgemm" : "cgemm"),
			cuMpSGEMM_get_compute_mode_string(compute_mode),
			(op_A == CUBLAS_OP_N) ? "N" : ((op_A == CUBLAS_OP_T) ? "T" : "C"),
			(op_B == CUBLAS_OP_N) ? "N" : ((op_B == CUBLAS_OP_T) ? "T" : "C"),
			m, n, k,
			batch_count,
			throughput * 1e-12,
			residual,
			(check ? "OK" : "NG"),
			module_stage
			);
	std::fflush(stdout);

	if (check) {
		return 0;
	} else {
		return 1;
	}
}

void gemm_test(const std::size_t min_N, const std::size_t max_N, const std::size_t interval, const bool only_cublas, const gemm_type gemm, const bool is_seq) {
	constexpr uint64_t seed = 0;
	const std::size_t max_num_elements = (is_seq ? max_N * max_N : (1lu << (2 * max_N))) * (gemm == gemm_type::c ? 2 : 1);
	float* a_ptr = cutf::memory::malloc<float>(max_num_elements);
	float* b_ptr = cutf::memory::malloc<float>(max_num_elements);
	float* c_ptr = cutf::memory::malloc<float>(max_num_elements);

	auto curand_gen = cutf::curand::get_curand_unique_ptr(CURAND_RNG_PSEUDO_PHILOX4_32_10);
	CUTF_CHECK_ERROR(curandSetPseudoRandomGeneratorSeed(*curand_gen.get(), seed));
	CUTF_CHECK_ERROR(cutf::curand::generate_uniform(*curand_gen.get(), a_ptr, max_num_elements));
	CUTF_CHECK_ERROR(cutf::curand::generate_uniform(*curand_gen.get(), b_ptr, max_num_elements));

	std::vector<cuMpSGEMM_compute_mode_t> modes;

	if (!only_cublas) {
		modes.push_back(CUMPSGEMM_FP16TCEC);
		modes.push_back(CUMPSGEMM_FP16TC);
		modes.push_back(CUMPSGEMM_TF32TCEC);
		modes.push_back(CUMPSGEMM_TF32TC);
	} else {
		modes.push_back(CUMPSGEMM_CUBLAS);
	}

	std::vector<cublasOperation_t> sgemm_ops = {
		CUBLAS_OP_N,
		CUBLAS_OP_T
	};
	std::vector<cublasOperation_t> cgemm_ops = {
		CUBLAS_OP_N,
		CUBLAS_OP_T,
		CUBLAS_OP_C
	};

	std::printf("## %s\n", __func__);
	std::printf("type,mode,op_A,op_B,m,n,k,throughput_in_tflops,residual,check,module_stage\n");
	unsigned num_tests = 0;
	unsigned num_passed = 0;
	auto cublas_handle_uptr = cutf::cublas::get_cublas_unique_ptr();
	cuMpSGEMM_handle_t cuMpSGEMM_handle;
	cuMpSGEMM_create(&cuMpSGEMM_handle);

	std::vector<std::size_t> N_list;
	if (is_seq) {
		for (unsigned N = min_N; N <= max_N; N += interval) {
			N_list.push_back(N);
		}
	} else {
		for (unsigned N = min_N; N <= max_N; N += interval) {
			N_list.push_back(1lu << N);
		}
	}

	if (gemm == gemm_type::s) {
		for (const auto mode : modes) {
			for (const auto op_A : sgemm_ops) {
				for (const auto op_B : sgemm_ops) {
					for (const auto N : N_list) {
						const auto res = sgemm_test_core(
								*cublas_handle_uptr.get(),
								cuMpSGEMM_handle,
								op_A,
								op_B,
								N, N, N,
								a_ptr, N,
								b_ptr, N,
								c_ptr, N,
								mode
								);
						num_tests++;
						if (res == 0) {
							num_passed++;
						}
					}
				}
			}
		}
	} else if (gemm == gemm_type::c) {
		for (const auto mode : modes) {
			for (const auto op_A : cgemm_ops) {
				for (const auto op_B : cgemm_ops) {
					for (const auto N : N_list) {
						const auto res = sgemm_test_core(
								*cublas_handle_uptr.get(),
								cuMpSGEMM_handle,
								op_A,
								op_B,
								N, N, N,
								reinterpret_cast<cuComplex*>(a_ptr), N,
								reinterpret_cast<cuComplex*>(b_ptr), N,
								reinterpret_cast<cuComplex*>(c_ptr), N,
								mode
								);
						num_tests++;
						if (res == 0) {
							num_passed++;
						}
					}
				}
			}
		}
	}
	CUTF_CHECK_ERROR(cudaDeviceSynchronize());

	std::printf("Result : %u / %u passed\n",
			num_passed,
			num_tests
			);

	cuMpSGEMM_destroy(cuMpSGEMM_handle);

	cutf::memory::free(a_ptr);
	cutf::memory::free(b_ptr);
	cutf::memory::free(c_ptr);
}

void gemm_strided_batch_test(const std::size_t min_N, const std::size_t max_N, const std::size_t interval, const std::size_t batch_count, const bool only_cublas, const gemm_type gemm, const bool is_seq) {
	constexpr uint64_t seed = 0;
	const std::size_t max_num_elements = (is_seq ? max_N * max_N : (1lu << (2 * max_N))) * (gemm == gemm_type::c ? 2 : 1) * batch_count;
	float* a_ptr = cutf::memory::malloc<float>(max_num_elements);
	float* b_ptr = cutf::memory::malloc<float>(max_num_elements);
	float* c_ptr = cutf::memory::malloc<float>(max_num_elements);

	auto curand_gen = cutf::curand::get_curand_unique_ptr(CURAND_RNG_PSEUDO_PHILOX4_32_10);
	CUTF_CHECK_ERROR(curandSetPseudoRandomGeneratorSeed(*curand_gen.get(), seed));
	CUTF_CHECK_ERROR(cutf::curand::generate_uniform(*curand_gen.get(), a_ptr, max_num_elements));
	CUTF_CHECK_ERROR(cutf::curand::generate_uniform(*curand_gen.get(), b_ptr, max_num_elements));


	std::vector<cuMpSGEMM_compute_mode_t> modes;

	if (!only_cublas) {
		modes.push_back(CUMPSGEMM_FP16TCEC);
		modes.push_back(CUMPSGEMM_FP16TC);
		modes.push_back(CUMPSGEMM_TF32TCEC);
		modes.push_back(CUMPSGEMM_TF32TC);
	} else {
		modes.push_back(CUMPSGEMM_CUBLAS);
	}

	std::vector<cublasOperation_t> sgemm_ops = {
		CUBLAS_OP_N,
		CUBLAS_OP_T
	};
	std::vector<cublasOperation_t> cgemm_ops = {
		CUBLAS_OP_N,
		CUBLAS_OP_T,
		CUBLAS_OP_C
	};

	std::vector<std::size_t> N_list;
	if (is_seq) {
		for (unsigned N = min_N; N <= max_N; N += interval) {
			N_list.push_back(N);
		}
	} else {
		for (unsigned N = min_N; N <= max_N; N += interval) {
			N_list.push_back(1lu << N);
		}
	}

	std::printf("## %s\n", __func__);
	std::printf("type,mode,op_A,op_B,m,n,k,batch_count,throughput_in_tflops,residual,check,module_stage\n");
	unsigned num_tests = 0;
	unsigned num_passed = 0;
	auto cublas_handle_uptr = cutf::cublas::get_cublas_unique_ptr();
	cuMpSGEMM_handle_t cuMpSGEMM_handle;
	cuMpSGEMM_create(&cuMpSGEMM_handle);

	const auto stride = is_seq ? max_N * max_N : (1lu << (2 * max_N));

	if (gemm == gemm_type::s) {
		for (const auto mode : modes) {
			for (const auto op_A : sgemm_ops) {
				for (const auto op_B : sgemm_ops) {
					for (const auto N : N_list) {
						const auto res = sgemm_strided_batch_test_core(
								*cublas_handle_uptr.get(),
								cuMpSGEMM_handle,
								op_A,
								op_B,
								N, N, N,
								a_ptr, N, stride,
								b_ptr, N, stride,
								c_ptr, N, stride,
								batch_count,
								mode
								);
						num_tests++;
						if (res == 0) {
							num_passed++;
						}
					}
				}
			}
		}
	} else if (gemm == gemm_type::c) {
		for (const auto mode : modes) {
			for (const auto op_A : cgemm_ops) {
				for (const auto op_B : cgemm_ops) {
					for (const auto N : N_list) {
						const auto res = sgemm_strided_batch_test_core(
								*cublas_handle_uptr.get(),
								cuMpSGEMM_handle,
								op_A,
								op_B,
								N, N, N,
								reinterpret_cast<cuComplex*>(a_ptr), N, stride,
								reinterpret_cast<cuComplex*>(b_ptr), N, stride,
								reinterpret_cast<cuComplex*>(c_ptr), N, stride,
								batch_count,
								mode
								);
						num_tests++;
						if (res == 0) {
							num_passed++;
						}
					}
				}
			}
		}
	}
	CUTF_CHECK_ERROR(cudaDeviceSynchronize());

	std::printf("Result : %u / %u passed\n",
			num_passed,
			num_tests
			);

	cuMpSGEMM_destroy(cuMpSGEMM_handle);

	cutf::memory::free(a_ptr);
	cutf::memory::free(b_ptr);
	cutf::memory::free(c_ptr);
}

// [cuMpSGEMM LOG] cublasCgemm_v2 op=(N, T), shape=(4, 128, 65536), mode=TF32TCEC
void test_logged_shape(
		const std::string log_path
		) {
	std::ifstream ifs(log_path);
	if (!ifs) {
		throw std::runtime_error("No such file : " + log_path);
	}

	auto cublas_handle_uptr = cutf::cublas::get_cublas_unique_ptr();

	cuMpSGEMM_handle_t cuMpSGEMM_handle;
	cuMpSGEMM_create(&cuMpSGEMM_handle);

	std::size_t num_passed = 0;
	std::size_t num_tested = 0;
	std::printf("## %s\n", __func__);
	const std::string log_prefix = "[cuMpSGEMM LOG] ";
	std::string buffer;
	while (std::getline(ifs, buffer)) {
		if (buffer.find(log_prefix) == std::string::npos) {
			continue;
		}
		buffer = buffer.substr(log_prefix.length());
		std::regex base_regex(R"((\w+) (.+), mode=(.+))");
		std::smatch base_match;

		std::string func = "";
		std::string params = "";
		std::string mode = "";
		if (std::regex_match(buffer, base_match, base_regex)) {
			func = base_match[1].str();
			params = base_match[2].str();
			mode = base_match[3].str();
		}

		if (func.length() * params.length() * mode.length() == 0) {
			continue;
		}

		cuMpSGEMM_compute_mode_t compute_mode = CUMPSGEMM_CUBLAS;
		if (mode == "FP16TC") {
			compute_mode = CUMPSGEMM_FP16TC;
		} else if (mode == "FP16TCEC") {
			compute_mode = CUMPSGEMM_FP16TCEC;
		} else if (mode == "TF32TC") {
			compute_mode = CUMPSGEMM_TF32TC;
		} else if (mode == "TF32TCEC") {
			compute_mode = CUMPSGEMM_TF32TCEC;
		} else {
			throw std::runtime_error("Unknown compute mode : " + mode);
		}

		if (func == "cublasCgemm_v2" || func == "cublasSgemm_v2") {
			std::regex param_regex(R"(op=\((.), (.)\), shape=\((\d+), (\d+), (\d+)\))");
			std::smatch param_match;

			std::size_t m = 0, n = 0, k = 0;
			cublasOperation_t op_A, op_B;
			if (std::regex_match(params, param_match, param_regex) && param_match.size() > 1) {
				op_A = param_match[1].str() == "N" ? CUBLAS_OP_N : (param_match[1].str() == "T" ? CUBLAS_OP_T : CUBLAS_OP_C);
				op_B = param_match[2].str() == "N" ? CUBLAS_OP_N : (param_match[2].str() == "T" ? CUBLAS_OP_T : CUBLAS_OP_C);
				m = std::stoul(param_match[3].str());
				n = std::stoul(param_match[4].str());
				k = std::stoul(param_match[5].str());
			} else {
				throw std::runtime_error("Failed to parse parameters : " + params);
			}

			if (m * n * k == 0) {
				throw std::runtime_error("Invalid shape : (" + std::to_string(m) + ", " + std::to_string(n) + ", " + std::to_string(k) + ")");
			}
			constexpr uint64_t seed = 0;

			const std::size_t num_e = (func == "cublasSgemm_v2" ? 1 : 2);
			float* a_ptr = cutf::memory::malloc<float>(m * k * num_e);
			float* b_ptr = cutf::memory::malloc<float>(k * n * num_e);
			float* c_ptr = cutf::memory::malloc<float>(m * n * num_e);

			auto curand_gen = cutf::curand::get_curand_unique_ptr(CURAND_RNG_PSEUDO_PHILOX4_32_10);
			CUTF_CHECK_ERROR(curandSetPseudoRandomGeneratorSeed(*curand_gen.get(), seed));
			CUTF_CHECK_ERROR(cutf::curand::generate_uniform(*curand_gen.get(), a_ptr, m * k * num_e));
			CUTF_CHECK_ERROR(cutf::curand::generate_uniform(*curand_gen.get(), b_ptr, k * n * num_e));
			int res;
			if (func == "cublasSgemm_v2") {
				res = sgemm_test_core(
						*cublas_handle_uptr.get(),
						cuMpSGEMM_handle,
						op_A,
						op_B,
						m, n, k,
						a_ptr, (op_A == CUBLAS_OP_N ? m : k),
						b_ptr, (op_B == CUBLAS_OP_N ? k : n),
						c_ptr, m,
						compute_mode
						);
			} else {
				res = sgemm_test_core(
						*cublas_handle_uptr.get(),
						cuMpSGEMM_handle,
						op_A,
						op_B,
						m, n, k,
						reinterpret_cast<cuComplex*>(a_ptr), (op_A == CUBLAS_OP_N ? m : k),
						reinterpret_cast<cuComplex*>(b_ptr), (op_B == CUBLAS_OP_N ? k : n),
						reinterpret_cast<cuComplex*>(c_ptr), m,
						compute_mode
						);
			}
			if (res == 0) {
				num_passed++;
			}
			num_tested++;

			cutf::memory::free(a_ptr);
			cutf::memory::free(b_ptr);
			cutf::memory::free(c_ptr);
		} else if (func == "cublasSgemmStridedBatched" || func == "cublasCgemmStridedBatched") {
			std::regex param_regex(R"(op=\((.), (.)\), shape=\((\d+), (\d+), (\d+)\), batch=([0-9]+))");
			std::smatch param_match;

			std::size_t m = 0, n = 0, k = 0;
			std::size_t batch_size = 0;
			cublasOperation_t op_A, op_B;
			if (std::regex_match(params, param_match, param_regex) && param_match.size() > 1) {
				op_A = param_match[1].str() == "N" ? CUBLAS_OP_N : (param_match[1].str() == "T" ? CUBLAS_OP_T : CUBLAS_OP_C);
				op_B = param_match[2].str() == "N" ? CUBLAS_OP_N : (param_match[2].str() == "T" ? CUBLAS_OP_T : CUBLAS_OP_C);
				m = std::stoul(param_match[3].str());
				n = std::stoul(param_match[4].str());
				k = std::stoul(param_match[5].str());
				batch_size = std::stoul(param_match[6].str());
			} else {
				throw std::runtime_error("Failed to parse parameters : " + params);
			}

			if (m * n * k * batch_size == 0) {
				throw std::runtime_error("Invalid shape : (" + std::to_string(m) + ", " + std::to_string(n) + ", " + std::to_string(k) + "), batch_size = " + std::to_string(batch_size));
			}
			constexpr uint64_t seed = 0;

			const std::size_t num_e = (func == "cublasSgemmStridedBatched" ? 1 : 2);
			float* a_ptr = cutf::memory::malloc<float>(m * k * num_e * batch_size);
			float* b_ptr = cutf::memory::malloc<float>(k * n * num_e * batch_size);
			float* c_ptr = cutf::memory::malloc<float>(m * n * num_e * batch_size);

			auto curand_gen = cutf::curand::get_curand_unique_ptr(CURAND_RNG_PSEUDO_PHILOX4_32_10);
			CUTF_CHECK_ERROR(curandSetPseudoRandomGeneratorSeed(*curand_gen.get(), seed));
			CUTF_CHECK_ERROR(cutf::curand::generate_uniform(*curand_gen.get(), a_ptr, m * k * num_e * batch_size));
			CUTF_CHECK_ERROR(cutf::curand::generate_uniform(*curand_gen.get(), b_ptr, k * n * num_e * batch_size));
			int res;
			if (func == "cublasSgemmStridedBatched") {
				res = sgemm_strided_batch_test_core(
						*cublas_handle_uptr.get(),
						cuMpSGEMM_handle,
						op_A,
						op_B,
						m, n, k,
						a_ptr, (op_A == CUBLAS_OP_N ? m : k), m * k,
						b_ptr, (op_B == CUBLAS_OP_N ? k : n), k * n,
						c_ptr, m, m * n,
						batch_size,
						compute_mode
						);
			} else {
				res = sgemm_strided_batch_test_core(
						*cublas_handle_uptr.get(),
						cuMpSGEMM_handle,
						op_A,
						op_B,
						m, n, k,
						reinterpret_cast<cuComplex*>(a_ptr), (op_A == CUBLAS_OP_N ? m : k), m * k,
						reinterpret_cast<cuComplex*>(b_ptr), (op_B == CUBLAS_OP_N ? k : n), k * n,
						reinterpret_cast<cuComplex*>(c_ptr), m, m * n,
						batch_size,
						compute_mode
						);
			}
			if (res == 0) {
				num_passed++;
			}
			num_tested++;

			cutf::memory::free(a_ptr);
			cutf::memory::free(b_ptr);
			cutf::memory::free(c_ptr);
		}
	}
	ifs.close();
	std::printf("%lu / %lu passed\n", num_passed, num_tested);

	cuMpSGEMM_destroy(cuMpSGEMM_handle);
}

void gemm_exp_stats_test(
		const std::size_t N,
		const float ignore_threshold,
		const float lose_threshold,
		const gemm_type gemm
		) {
	constexpr uint64_t seed = 0;
	const std::size_t max_num_elements = N * N * (gemm == gemm_type::c ? 2 : 1);
	float* a_ptr = cutf::memory::malloc<float>(max_num_elements);
	float* b_ptr = cutf::memory::malloc<float>(max_num_elements);
	float* c_ptr = cutf::memory::malloc<float>(max_num_elements);

	auto curand_gen = cutf::curand::get_curand_unique_ptr(CURAND_RNG_PSEUDO_PHILOX4_32_10);
	CUTF_CHECK_ERROR(curandSetPseudoRandomGeneratorSeed(*curand_gen.get(), seed));
	CUTF_CHECK_ERROR(cutf::curand::generate_uniform(*curand_gen.get(), a_ptr, max_num_elements));
	CUTF_CHECK_ERROR(cutf::curand::generate_uniform(*curand_gen.get(), b_ptr, max_num_elements));

	std::printf("## %s\n", __func__);
	auto cublas_handle_uptr = cutf::cublas::get_cublas_unique_ptr();
	cuMpSGEMM_handle_t cuMpSGEMM_handle;
	cuMpSGEMM_create(&cuMpSGEMM_handle);
	cumpsgemm::enable_exp_stats(cuMpSGEMM_handle);
	cumpsgemm::set_exp_stats_params(cuMpSGEMM_handle, ignore_threshold, lose_threshold);

	std::vector<cuMpSGEMM_compute_mode_t> modes;

	modes.push_back(CUMPSGEMM_FP16TCEC);
	modes.push_back(CUMPSGEMM_FP16TC);
	modes.push_back(CUMPSGEMM_TF32TCEC);
	modes.push_back(CUMPSGEMM_TF32TC);

	for (const auto compute_mode : modes) {
		if (gemm == gemm_type::s) {
			const float alpha = 1.0f, beta = 0.0f;
			cumpsgemm::gemm(
					cuMpSGEMM_handle,
					CUBLAS_OP_N,
					CUBLAS_OP_N,
					N, N, N,
					&alpha,
					a_ptr, N,
					b_ptr, N,
					&beta,
					c_ptr, N,
					compute_mode
					);
		} else {
			const cuComplex alpha = make_float2(1, 0);
			const cuComplex beta = make_float2(1, 0);
			cumpsgemm::gemm(
					cuMpSGEMM_handle,
					CUBLAS_OP_N,
					CUBLAS_OP_N,
					N, N, N,
					&alpha,
					reinterpret_cast<const cuComplex*>(a_ptr), N,
					reinterpret_cast<const cuComplex*>(b_ptr), N,
					&beta,
					reinterpret_cast<cuComplex*>(c_ptr), N,
					compute_mode
					);
		}
		const auto buffer_id = cumpsgemm::get_current_buffer_id(cuMpSGEMM_handle);
		const auto exp_stats = cumpsgemm::get_exp_stats(cuMpSGEMM_handle, buffer_id);
		std::printf("[%s:%8s] R_FP16TCEC = %lu / %lu (%6.2f), buffer_id = %u\n",
				(gemm == gemm_type::s ? "sgemm" : "cgemm"),
				cuMpSGEMM_get_compute_mode_string(compute_mode),
				exp_stats.first, exp_stats.second, static_cast<double>(exp_stats.first) / exp_stats.second,
				buffer_id);
	}
}

void gemm_strided_batch_exp_stats_test(
		const std::size_t N,
		const std::size_t batch_size,
		const float ignore_threshold,
		const float lose_threshold,
		const gemm_type gemm
		) {
	constexpr uint64_t seed = 0;
	const std::size_t max_num_elements = N * N * batch_size * (gemm == gemm_type::c ? 2 : 1);
	float* a_ptr = cutf::memory::malloc<float>(max_num_elements);
	float* b_ptr = cutf::memory::malloc<float>(max_num_elements);
	float* c_ptr = cutf::memory::malloc<float>(max_num_elements);

	auto curand_gen = cutf::curand::get_curand_unique_ptr(CURAND_RNG_PSEUDO_PHILOX4_32_10);
	CUTF_CHECK_ERROR(curandSetPseudoRandomGeneratorSeed(*curand_gen.get(), seed));
	CUTF_CHECK_ERROR(cutf::curand::generate_uniform(*curand_gen.get(), a_ptr, max_num_elements));
	CUTF_CHECK_ERROR(cutf::curand::generate_uniform(*curand_gen.get(), b_ptr, max_num_elements));

	std::printf("## %s\n", __func__);
	auto cublas_handle_uptr = cutf::cublas::get_cublas_unique_ptr();
	cuMpSGEMM_handle_t cuMpSGEMM_handle;
	cuMpSGEMM_create(&cuMpSGEMM_handle);
	cumpsgemm::enable_exp_stats(cuMpSGEMM_handle);
	cumpsgemm::set_exp_stats_params(cuMpSGEMM_handle, ignore_threshold, lose_threshold);

	std::vector<cuMpSGEMM_compute_mode_t> modes;

	modes.push_back(CUMPSGEMM_FP16TCEC);
	modes.push_back(CUMPSGEMM_FP16TC);
	modes.push_back(CUMPSGEMM_TF32TCEC);
	modes.push_back(CUMPSGEMM_TF32TC);

	for (const auto compute_mode : modes) {
		if (gemm == gemm_type::s) {
			const float alpha = 1.0f, beta = 0.0f;
			cumpsgemm::gemm_stridedBatch(
					cuMpSGEMM_handle,
					CUBLAS_OP_N,
					CUBLAS_OP_N,
					N, N, N,
					&alpha,
					a_ptr, N, N * N,
					b_ptr, N, N * N,
					&beta,
					c_ptr, N, N * N,
					batch_size,
					CUMPSGEMM_TF32TCEC
					);
		} else {
			const cuComplex alpha = make_float2(1, 0);
			const cuComplex beta = make_float2(1, 0);
			cumpsgemm::gemm_stridedBatch(
					cuMpSGEMM_handle,
					CUBLAS_OP_N,
					CUBLAS_OP_N,
					N, N, N,
					&alpha,
					reinterpret_cast<const cuComplex*>(a_ptr), N, N * N,
					reinterpret_cast<const cuComplex*>(b_ptr), N, N * N,
					&beta,
					reinterpret_cast<cuComplex*>(c_ptr), N, N * N,
					batch_size,
					CUMPSGEMM_TF32TCEC
					);
		}
		const auto buffer_id = cumpsgemm::get_current_buffer_id(cuMpSGEMM_handle);
		const auto exp_stats = cumpsgemm::get_exp_stats(cuMpSGEMM_handle, buffer_id);
		std::printf("[%s:%8s] R_FP16TCEC = %lu / %lu (%6.2f), buffer_id = %u\n",
				(gemm == gemm_type::s ? "sgemm" : "cgemm"),
				cuMpSGEMM_get_compute_mode_string(compute_mode),
				exp_stats.first, exp_stats.second, static_cast<double>(exp_stats.first) / exp_stats.second,
				buffer_id);
	}
}

void print_usage(const char* program_name) {
	std::fprintf(stderr,
			"Usage : %s sgemm [exp2|seq] [min_N] [max_N] [interval]\n"
			"      : %s cgemm [exp2|seq] [min_N] [max_N] [interval]\n"
			"      : %s sgemm_strided_batch [exp2|seq] [min_N] [max_N] [interval] [batch_count]\n"
			"      : %s cgemm_strided_batch [exp2|seq] [min_N] [max_N] [interval] [batch_count]\n"
			"      : %s cublas_sgemm [exp2|seq] [min_N] [max_N] [interval]\n"
			"      : %s cublas_cgemm [exp2|seq] [min_N] [max_N] [interval]\n"
			"      : %s cublas_sgemm_strided_batch [exp2|seq] [min_N] [max_N] [interval] [batch_count]\n"
			"      : %s cublas_cgemm_strided_batch [exp2|seq] [min_N] [max_N] [interval] [batch_count]\n"
			"      : %s log [/path/to/log]\n"
			"      : %s sgemm_exp_stats [N] [ignore_threshold] [lost_threshold]\n"
			"      : %s cgemm_exp_stats [N] [ignore_threshold] [lost_threshold]\n"
			"      : %s sgemm_strided_batch_exp_stats [N] [batch_size] [ignore_threshold] [lost_threshold]\n"
			"      : %s cgemm_strided_batch_exp_stats [N] [batch_size] [ignore_threshold] [lost_threshold]\n",
			program_name, program_name, program_name, program_name, program_name, program_name, program_name, program_name, program_name, program_name, program_name, program_name, program_name
			);
	std::fflush(stderr);
}

int main(int argc, char** argv) {
	if (argc < 2) {
		print_usage(argv[0]);
		return 1;
	}

	const std::string command = argv[1];

	if (command == "log") {
		if (argc < 1 + 1 + 1) {
			print_usage(argv[0]);
			return 1;
		}
		test_logged_shape(argv[2]);
		return 0;
	} else if (command == "sgemm_exp_stats" || command == "cgemm_exp_stats") {
		if (argc < 1 + 1 + 3) {
			print_usage(argv[0]);
			return 1;
		}
		gemm_exp_stats_test(std::stoi(argv[2]), std::stof(argv[3]), std::stof(argv[4]), (command == "sgemm_exp_stats" ? gemm_type::s : gemm_type::c));
		return 0;
	} else if (command == "sgemm_strided_batch_exp_stats" || command == "cgemm_strided_batch_exp_stats") {
		if (argc < 1 + 1 + 4) {
			print_usage(argv[0]);
			return 1;
		}
		gemm_strided_batch_exp_stats_test(std::stoi(argv[2]), std::stoi(argv[3]), std::stof(argv[4]), std::stof(argv[5]), (command == "sgemm_strided_batch_exp_stats" ? gemm_type::s : gemm_type::c));
		return 0;
	}

	if (argc < 3 || (std::string(argv[2]) != "exp2" && std::string(argv[2]) != "seq")) {
		std::fprintf(stderr, "[cuMpSGEMM test] invalid argument\n");
		return 1;
	}

	const bool is_seq = std::string(argv[2]) != "exp2";

	if (command == "sgemm" || command == "cgemm") {
		if (argc < 1 + 1 + 3) {
			print_usage(argv[0]);
			return 1;
		}
		gemm_test(std::stoi(argv[3]), std::stoi(argv[4]), std::stoi(argv[5]), false, (command == "sgemm" ? gemm_type::s : gemm_type::c), is_seq);
	} else if (command == "sgemm_strided_batch" || command == "cgemm_strided_batch") {
		if (argc < 1 + 1 + 3 + 1) {
			print_usage(argv[0]);
			return 1;
		}
		gemm_strided_batch_test(std::stoi(argv[3]), std::stoi(argv[4]), std::stoi(argv[5]), std::stoi(argv[6]), false, (command == "sgemm_strided_batch" ? gemm_type::s : gemm_type::c), is_seq);
	} else if (command == "cublas_sgemm" || command == "cublas_cgemm") {
		if (argc < 1 + 1 + 3) {
			print_usage(argv[0]);
			return 1;
		}
		gemm_test(std::stoi(argv[3]), std::stoi(argv[4]), std::stoi(argv[5]), true, (command == "cublas_sgemm" ? gemm_type::s : gemm_type::c), is_seq);
	} else if (command == "cublas_sgemm_strided_batch" || command == "cublas_cgemm_strided_batch") {
		if (argc < 1 + 1 + 3 + 1) {
			print_usage(argv[0]);
			return 1;
		}
		gemm_strided_batch_test(std::stoi(argv[3]), std::stoi(argv[4]), std::stoi(argv[5]), std::stoi(argv[6]), true, (command == "cublas_sgemm_strided_batch" ? gemm_type::s : gemm_type::c), is_seq);
	} else {
		print_usage(argv[0]);
		return 1;
	}
}
