TEST_TIME=300

RATE_LIMIT=50         # make sure avg(rpc) little than 20ms.
THREAD_NUM=6          # proxy number * 2
CLI_PER_THREAD=200

# REDIS_CMD=set __key__ __data__ ex 86400
REDIS_CMD=get __key__

DATA_SIZE_RANGE=32-128

KEY_PREFIX=test_string_v2

.PHONY: default check unit-test integration-test test all debug release


default: check debug

check:
	cargo check --all --all-targets --all-features
	cargo fmt -- --check
	# cargo clippy --all-targets --all-features -- -D clippy::all

debug:
	cargo build

release:
	cargo build --release

unit-test:
	cargo test --all

integration-test:
	@echo "start tikv-service manually"
	python3 test/test_helper.py -p 6666

test: unit-test integration-test

all: check test

run: debug
	rm -rf tikv-service.log
	./target/debug/tidis-server --config config.toml

run_ytl: debug
	rm -rf tikv-service.log
	./target/debug/tidis-server --config config.ytl-nvme.toml

run_release: release 
	rm -rf tikv-service.log
	./target/release/tidis-server --config config.toml

clean: 
	rm -rf ./target/*

update:
	cargo update tikv-client

cli:
	redis-cli -h 127.0.0.1 -p 6666 set x 1
	redis-cli -h 127.0.0.1 -p 6666 get x

cli_ap:
	redis-cli -h 127.0.0.1 -p 6379 -a app_onebox@db_onebox@goclient_redistable_test2@ get x

cli_ytl_tidis:
	redis-cli -h 10.242.2.94 -p 6679 get x

fmt:
	cargo fmt

commit: fmt
	git add ./; git commit -m "x"; git push 
	git push gitlab_origin

metric:
	curl '127.0.0.1:8080/metrics'

docker_build:
	docker build -t x -f ./Dockerfile.kvstore ./

bench:
	memtier_benchmark --server 127.0.0.1 --port 6666  -c 10 -t 10 --pipeline 1 --key-prefix=${KEY_PREFIX} --key-minimum=104000000000 --key-maximum=105000000000 --random-data --data-size-range=${DATA_SIZE_RANGE} --command="${REDIS_CMD}" --requests=2000


bench_local_to_ytl_nvme: 
	memtier_benchmark --server 127.0.0.1 --port 6666  -c ${CLI_PER_THREAD} -t ${THREAD_NUM} --pipeline 1 --key-prefix=${KEY_PREFIX} --key-minimum=104000000000 --key-maximum=105000000000 --random-data --data-size-range=${DATA_SIZE_RANGE} --command="${REDIS_CMD}" --requests=20000000000000

info:
	strings ./target/debug/tidis-server | grep jemalloc
	# objdump -T ./target/debug/tidis-server | grep je_
	nm -an ./target/debug/tidis-server | grep je_


bench_ytl_ap:
	memtier_benchmark --server 10.242.2.90 --port 6679 --authenticate=sla_test@test-redis-v65-v1-ytl@sla_test_redis@c0563e318876dc9c5f6043b68eeadef5  -c ${CLI_PER_THREAD} -t ${THREAD_NUM} --pipeline 1 --key-prefix=${KEY_PREFIX} --key-minimum=104000000000 --key-maximum=105000000000 --random-data --data-size-range=${DATA_SIZE_RANGE} --command="${REDIS_CMD}"  --test-time=${TEST_TIME} --rate-limit=${RATE_LIMIT}

bench_ytl_tidis:
	memtier_benchmark --server 10.242.2.94 --port 6679  -c ${CLI_PER_THREAD} -t ${THREAD_NUM} --pipeline 1 --key-prefix=${KEY_PREFIX} --key-minimum=104000000000 --key-maximum=105000000000 --random-data --data-size-range=${DATA_SIZE_RANGE} --command="${REDIS_CMD}"  --test-time=${TEST_TIME}  --rate-limit=${RATE_LIMIT}


bench_ytl_nvme_ap:
	memtier_benchmark --server 10.242.2.91 --port 6679 --authenticate=sla_test@test-redis-v65-v1-nvme-ytl@sla_test_redis@c0563e318876dc9c5f6043b68eeadef5  -c ${CLI_PER_THREAD} -t ${THREAD_NUM} --pipeline 1 --key-prefix=${KEY_PREFIX} --key-minimum=104000000000 --key-maximum=105000000000 --random-data --data-size-range=${DATA_SIZE_RANGE} --command="${REDIS_CMD}"  --test-time=${TEST_TIME} --rate-limit=${RATE_LIMIT}

bench_ytl_nvme_tidis:
	memtier_benchmark --server 10.242.2.93 --port 6679  -c ${CLI_PER_THREAD} -t ${THREAD_NUM} --pipeline 1 --key-prefix=${KEY_PREFIX} --key-minimum=104000000000 --key-maximum=105000000000 --random-data --data-size-range=${DATA_SIZE_RANGE} --command="${REDIS_CMD}"  --test-time=${TEST_TIME}  --rate-limit=${RATE_LIMIT}


bench_all:
	make bench_ytl_tidis && sleep 180 && make bench_ytl_ap && sleep 180 && make bench_ytl_tidis && sleep 180 && make bench_ytl_ap

bench_all_nvme:
	make bench_ytl_nvme_tidis && sleep 180 && make bench_ytl_nvme_ap && sleep 180

bench_all_nvme_5:
	make bench_all_nvme && make bench_all_nvme && make bench_all_nvme && make bench_all_nvme && make bench_all_nvme

clean_log:
	rm -rf tikv-service.log
