env
BATCH_TIMEOUT_S="${collector.batch_timeout_s}"
BATCH_SEND_SIZE="${collector.batch_send_size}"
TAIL_DECISION_WAIT_S="${collector.tail_decision_wait_s}"
TAIL_NUM_TRACES="${collector.tail_num_traces}"
MEMORY_LIMIT_MIB="${collector.memory_limit_mib}"
MEMORY_SPIKE_MIB="${collector.memory_spike_mib}"
GOGC="${collector.gogc}"
GOMEMLIMIT_MIB="${collector.gomemlimit_mib}"
GOMAXPROCS="${collector.gomaxprocs}"
bash /work/observability-on-edge/akamas/scripts/apply-config.sh