#!/bin/bash
# Template interpolated by Akamas FileConfigurator for each experiment.
# Placeholders ${collector.<name>} are replaced with the parameter values
# chosen by the optimiser before final.sh is executed.
#
# Variables are exported so that the apply-config.sh subprocess inherits them.
export BATCH_TIMEOUT_S="${collector.batch_timeout_s}"
export BATCH_SEND_SIZE="${collector.batch_send_size}"
export TAIL_DECISION_WAIT_S="${collector.tail_decision_wait_s}"
export TAIL_NUM_TRACES="${collector.tail_num_traces}"
export MEMORY_LIMIT_MIB="${collector.memory_limit_mib}"
export MEMORY_SPIKE_MIB="${collector.memory_spike_mib}"
export GOGC="${collector.gogc}"
export GOMEMLIMIT_MIB="${collector.gomemlimit_mib}"
export GOMAXPROCS="${collector.gomaxprocs}"

exec bash /work/observability-on-edge/akamas/scripts/apply-config.sh