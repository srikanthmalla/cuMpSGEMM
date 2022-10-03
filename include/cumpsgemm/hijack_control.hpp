#pragma once
#include <string>
#include <vector>
#include "detail/common.h"

namespace cumpsgemm {
namespace hijack_control {
cuMpSGEMM_handle_t get_internal_global_handle();

void set_compute_mode(const cuMpSGEMM_compute_mode_t mode);
void unset_compute_mode();

void enable_exp_stats();
void disable_exp_stats();
std::pair<std::size_t, std::size_t> get_exp_stats(const unsigned buffer_id);
unsigned get_current_buffer_id();
void reset_buffer_id();
void set_exp_stats_params(
		const float ignore_threshold,
		const float lost_threshold
		);
void exp_stats(
		const unsigned m,
		const unsigned n,
		const float* const ptr,
		const unsigned ld,
		const unsigned batch_size = 1,
		const unsigned stride = 0
		);
bool is_exp_stats_enabled();
std::string get_last_called_function_str();
void set_last_called_function_str(const std::string func_str);
void clear_last_called_function_str();
} // namespace hijack_control
} // namespace cumpsgemm
