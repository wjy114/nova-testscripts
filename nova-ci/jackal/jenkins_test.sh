#!/usr/bin/bash

./prepare_env.sh
. venv/bin/activate
./run_tests.py --runner gce -v --tests xfstests1 --configs baseline1