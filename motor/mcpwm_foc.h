/*
	Copyright 2016 - 2020 Benjamin Vedder	benjamin@vedder.se

	This file is part of the VESC firmware.

	The VESC firmware is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    The VESC firmware is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with this program.  If not, see <http://www.gnu.org/licenses/>.
    */

#ifndef MCPWM_FOC_H_
#define MCPWM_FOC_H_

#include "conf_general.h"
#include "datatypes.h"
#include "foc_math.h"
#include <stdbool.h>


typedef enum {
	ENGINE_START_PARAM_ALIGN_CURRENT = 0,
	ENGINE_START_PARAM_ALIGN_TIME_MS,
	ENGINE_START_PARAM_PULL_CURRENT,
	ENGINE_START_PARAM_PULL_START_ERPM,
	ENGINE_START_PARAM_PULL_TARGET_ERPM,
	ENGINE_START_PARAM_PULL_RAMP_ERPM_S,
	ENGINE_START_PARAM_BOOST_CURRENT,
	ENGINE_START_PARAM_BOOST_TIME_MS,
	ENGINE_START_PARAM_BOOST_CURRENT_1,
	ENGINE_START_PARAM_BOOST_CURRENT_2,
	ENGINE_START_PARAM_BOOST_CURRENT_3,
	ENGINE_START_PARAM_BOOST_PULSE_MS,
	ENGINE_START_PARAM_BOOST_GAP_MS,
	ENGINE_START_PARAM_BOOST_MAX_PULSES,
	ENGINE_START_PARAM_BOOST_SUCCESS_ERPM,
	ENGINE_START_PARAM_ACCEL_CURRENT,
	ENGINE_START_PARAM_ACCEL_TARGET_ERPM,
	ENGINE_START_PARAM_ACCEL_RAMP_ERPM_S,
	ENGINE_START_PARAM_OBS_MIN_ERPM,
	ENGINE_START_PARAM_BLEND_TIME_MS,
	ENGINE_START_PARAM_RETRY_DELAY_MS,
	ENGINE_START_PARAM_MAX_RETRY,
	ENGINE_START_PARAM_MAX_START_TIME_MS,
	ENGINE_START_PARAM_STALL_ERPM,
	ENGINE_START_PARAM_STALL_CURRENT,
	ENGINE_START_PARAM_STALL_DUTY,
	ENGINE_START_PARAM_COMPRESSION_TIME_MS,
	ENGINE_START_PARAM_OBS_STABLE_TIME_MS,
	ENGINE_START_PARAM_DIRECTION,
	ENGINE_START_PARAM_STALL_CONFIRM_MS,
	ENGINE_START_PARAM_MAX_TOTAL_PULSES,
	ENGINE_START_PARAM_MIN_VIN,
	ENGINE_START_PARAM_BACKOFF_MS,
	ENGINE_START_PARAM_BACKOFF_REVERSE_ENABLE,
	ENGINE_START_PARAM_BACKOFF_CURRENT,
	ENGINE_START_PARAM_BACKOFF_ERPM,
	ENGINE_START_PARAM_ENGINE_PERIOD_MS,
	ENGINE_START_PARAM_PREWARN_HOLD_MS,
	ENGINE_START_PARAM_PULSE_RATIO,
	ENGINE_START_PARAM_PREWARN_RATIO,
	ENGINE_START_PARAM_GAP_RATIO,
	ENGINE_START_PARAM_NUM
} engine_start_param_id_t;

typedef enum {
	ENGINE_STOP_NONE = 0,
	ENGINE_STOP_USER,
	ENGINE_STOP_TIMEOUT,
	ENGINE_STOP_UNDERVOLTAGE,
	ENGINE_STOP_FAULT,
	ENGINE_STOP_MAX_RETRY,
	ENGINE_STOP_MAX_PULSES,
	ENGINE_STOP_STALL,
	ENGINE_STOP_OVERCURRENT
} engine_start_stop_reason_t;

typedef struct {
	int state;
	bool active;
	int retry_count;
	int boost_pulse_count;
	int total_pulse_count;
	float openloop_erpm;
	float openloop_phase;
	float blend;
	float iq_target;
	float erpm_abs_filt;
	float current_abs_filt;
	float duty_abs_filt;
	float accel_filt;
	float load_score;
	float load_delta;
	int compression_ms;
	int stall_ms;
	int obs_stable_ms;
	int last_stop_reason;
	float stability_score;
	int learning_state;
	int learning_window_count;
	int consecutive_success;
	int strategy;
	int knowledge_count;
	float avg_start_time_ms;
	float v6_confidence;
	float learning_gain;
	int policy_mode;
	int timing_mode;
} engine_start_status_t;

// Functions
void mcpwm_foc_init(mc_configuration *conf_m1, mc_configuration *conf_m2);
void mcpwm_foc_deinit(void);
bool mcpwm_foc_init_done(void);
void mcpwm_foc_set_configuration(mc_configuration *configuration);
mc_state mcpwm_foc_get_state(void);
mc_control_mode mcpwm_foc_control_mode(void);
bool mcpwm_foc_is_dccal_done(void);
int mcpwm_foc_isr_motor(void);
void mcpwm_foc_stop_pwm(bool is_second_motor);
void mcpwm_foc_set_duty(float dutyCycle);
void mcpwm_foc_set_duty_noramp(float dutyCycle);
void mcpwm_foc_set_pid_speed(float rpm);
void mcpwm_foc_set_pid_pos(float pos);
void mcpwm_foc_set_current(float current);
void mcpwm_foc_release_motor(void);
void mcpwm_foc_set_brake_current(float current);
void mcpwm_foc_set_handbrake(float current);
void mcpwm_foc_set_openloop_current(float current, float rpm);
void mcpwm_foc_set_openloop_phase(float current, float phase);
void mcpwm_foc_set_openloop_duty(float dutyCycle, float rpm);
void mcpwm_foc_set_openloop_duty_phase(float dutyCycle, float phase);
void mcpwm_foc_engine_start(void);
void mcpwm_foc_engine_stop(void);
bool mcpwm_foc_engine_start_is_active(void);
bool mcpwm_foc_engine_start_set_param(engine_start_param_id_t param, float value);
bool mcpwm_foc_engine_start_get_param(engine_start_param_id_t param, float *value);
void mcpwm_foc_engine_start_reset_params(void);
bool mcpwm_foc_engine_start_get_status(engine_start_status_t *status);
void mcpwm_foc_set_fw_override(float current);
int mcpwm_foc_set_tachometer_value(int steps);
float mcpwm_foc_get_duty_cycle_set(void);
float mcpwm_foc_get_duty_cycle_now(void);
float mcpwm_foc_get_duty_cycle_abs_filter(void);
float mcpwm_foc_get_pid_speed_set(void);
float mcpwm_foc_get_pid_pos_set(void);
float mcpwm_foc_get_pid_pos_now(void);
float mcpwm_foc_get_switching_frequency_now(void);
float mcpwm_foc_get_sampling_frequency_now(void);
float mcpwm_foc_get_rpm(void);
float mcpwm_foc_get_rpm_fast(void);
float mcpwm_foc_get_rpm_faster(void);
float mcpwm_foc_get_tot_current(void);
float mcpwm_foc_get_tot_current_filtered(void);
float mcpwm_foc_get_abs_motor_current(void);
float mcpwm_foc_get_abs_motor_current_unbalance(void);
float mcpwm_foc_get_abs_motor_voltage(void);
float mcpwm_foc_get_abs_motor_current_filtered(void);
float mcpwm_foc_get_tot_current_directional(void);
float mcpwm_foc_get_tot_current_directional_filtered(void);
float mcpwm_foc_get_id(void);
float mcpwm_foc_get_iq(void);
float mcpwm_foc_get_id_set(void);
float mcpwm_foc_get_iq_set(void);
float mcpwm_foc_get_id_target(void);
float mcpwm_foc_get_iq_target(void);
float mcpwm_foc_get_id_filter(void);
float mcpwm_foc_get_iq_filter(void);
float mcpwm_foc_get_tot_current_in(void);
float mcpwm_foc_get_tot_current_in_filtered(void);
int mcpwm_foc_get_tachometer_value(bool reset);
int mcpwm_foc_get_tachometer_abs_value(bool reset);
float mcpwm_foc_get_phase(void);
float mcpwm_foc_get_phase_observer(void);
float mcpwm_foc_get_phase_bemf(void);
float mcpwm_foc_get_phase_encoder(void);
float mcpwm_foc_get_phase_hall(void);
float mcpwm_foc_get_vd(void);
float mcpwm_foc_get_vq(void);
float mcpwm_foc_get_mod_alpha_raw(void);
float mcpwm_foc_get_mod_beta_raw(void);
float mcpwm_foc_get_mod_alpha_measured(void);
float mcpwm_foc_get_mod_beta_measured(void);
float mcpwm_foc_get_v_alpha(void);
float mcpwm_foc_get_v_beta(void);
float mcpwm_foc_get_est_lambda(void);
float mcpwm_foc_get_est_res(void);
float mcpwm_foc_get_est_ind(void);
volatile const hfi_state_t *mcpwm_foc_get_hfi_state(void);
int mcpwm_foc_encoder_detect(float current, bool print, float *offset, float *ratio, bool *inverted);
int mcpwm_foc_measure_resistance(float current, int samples, bool stop_after, float *resistance);
int mcpwm_foc_measure_inductance(float duty, int samples, float *curr, float *ld_lq_diff, float *inductance);
int mcpwm_foc_measure_inductance_current(float curr_goal, int samples, float *curr, float *ld_lq_diff, float *inductance);

// Audio
bool mcpwm_foc_beep(float freq, float time, float voltage);
bool mcpwm_foc_play_tone(int channel, float freq, float voltage);
void mcpwm_foc_stop_audio(bool reset);
bool mcpwm_foc_set_audio_sample_table(int channel, const float *samples, int len);
const float *mcpwm_foc_get_audio_sample_table(int channel);
bool mcpwm_foc_play_audio_samples(const int8_t *samples, int num_samp, float f_samp, float voltage);

int mcpwm_foc_measure_res_ind(float *res, float *ind, float *ld_lq_diff);
int mcpwm_foc_hall_detect(float current, uint8_t *hall_table, bool *result);
int mcpwm_foc_dc_cal(bool cal_undriven);
void mcpwm_foc_print_state(void);
void mcpwm_foc_get_current_offsets(
		volatile float *curr0_offset,
		volatile float *curr1_offset,
		volatile float *curr2_offset,
		bool is_second_motor);
void mcpwm_foc_set_current_offsets(
		volatile float curr0_offset,
		volatile float curr1_offset,
		volatile float curr2_offset);
void mcpwm_foc_get_voltage_offsets(
		float *v0_offset,
		float *v1_offset,
		float *v2_offset,
		bool is_second_motor);
void mcpwm_foc_get_voltage_offsets_undriven(
		float *v0_offset,
		float *v1_offset,
		float *v2_offset,
		bool is_second_motor);
void mcpwm_foc_get_currents_adc(
		float *ph0,
		float *ph1,
		float *ph2,
		bool is_second_motor);
float mcpwm_foc_get_ts(void);
bool mcpwm_foc_is_using_encoder(void);
void mcpwm_foc_get_observer_state(float *x1, float *x2);
void mcpwm_foc_set_current_off_delay(float delay_sec);

// Functions where the motor can be selected
float mcpwm_foc_get_tot_current_motor(bool is_second_motor);
float mcpwm_foc_get_tot_current_filtered_motor(bool is_second_motor);
float mcpwm_foc_get_tot_current_in_motor(bool is_second_motor);
float mcpwm_foc_get_tot_current_in_filtered_motor(bool is_second_motor);
float mcpwm_foc_get_abs_motor_current_motor(bool is_second_motor);
float mcpwm_foc_get_abs_motor_current_filtered_motor(bool is_second_motor);
mc_state mcpwm_foc_get_state_motor(bool is_second_motor);

// Interrupt handlers
void mcpwm_foc_tim_sample_int_handler(void);
void mcpwm_foc_adc_int_handler(void *p, uint32_t flags);

// Defines
#ifndef MCPWM_FOC_CURRENT_SAMP_OFFSET
#define MCPWM_FOC_CURRENT_SAMP_OFFSET				(2) // Offset from timer top for ADC samples
#endif

#endif /* MCPWM_FOC_H_ */
