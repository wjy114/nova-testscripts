function _setup() {
    if ! [ -d "$NOVA_CI_LOG_DIR" ]; then
	new_result_dir
    fi
    export NOVA_CI_HOME=$HOME/nova-testscripts/nova-ci/
    export NOVA_CI_LOG_DIR=$NOVA_CI_HOME/results/latest
}

function init_tests() {
    if ! [ -f test_funcs.sh ]; then
	echo You are running in the wrong directory: $PWD
	return
    fi
    
    export NOVA_CI_HOME=$HOME/nova-testscripts/nova-ci/
    _setup
    K_SUFFIX=nova

    export NOVA_CI_PRIMARY_FS=/mnt/ramdisk
    export NOVA_CI_SECONDARY_FS=/mnt/scratch
    export NOVA_CI_PRIMARY_DEV=/dev/pmem0
    export NOVA_CI_SECONDARY_DEV=/dev/pmem1

    export NOVA_CI_KERNEL_NAME=$(get_kernel_version)

    export KERNEL_VERSION=$(get_kernel_version)

}

function _git() {
    for i in $NOVA_CI_HOME/ $NOVA_CI_HOME/linux-nova $NOVA_CI_HOME/{xfstests/xfstests,ltp/NOVA-ltp,fstest/pjd-fstest}; do
	echo ======================= $i ===========================
	(cd $i;
	 git $*
	)
    done | less
}



function new_result_dir() {

    if [ ".$1" != "." ]; then
	suffix="-$1"
    else
	suffix=""
    fi
    
    export NOVA_CI_DATE=$(date +"%F-%H-%M-%S.%N")
    R=$NOVA_CI_HOME/results/$NOVA_CI_DATE$suffix
    mkdir -p $R
    export NOVA_CI_LOG_DIR=$NOVA_CI_HOME/results/latest
    rm -f ${NOVA_CI_LOG_DIR}
    ln -sf $R  ${NOVA_CI_LOG_DIR}  
}

function enable_debugging() {
    echo "module nova +p" | sudo tee /sys/kernel/debug/dynamic_debug/control
}
function disable_debugging() {
    echo "module nova -p" | sudo tee /sys/kernel/debug/dynamic_debug/control
}

function bug_report() {
    _setup
    (
	set -v
	date
	hostname
	uname -a
	cat /proc/cmdline
	list_module_args nova
	df -k | grep nova
	(
	    set -v
	    cd $NOVA_CI_HOME/linux-nova;
	    git status
	    git log | head
	)
    )
}
function count_cpus() {
    cat /proc/cpuinfo  | grep processor | wc -l
}

function get_kernel_version() {
    _setup
    if [ -d $NOVA_CI_HOME/linux-nova ]; then
	(
	    cd $NOVA_CI_HOME/linux-nova; 
	    make kernelversion | perl -ne 'chop;print'
	    echo -${K_SUFFIX}
	)
    else
	echo "unknown"
    fi
}


function get_host_type() {
    if ps aux | grep -v grep | grep -q google_clock_skew_daemon; then
	echo gce
    else
	echo ubuntu
    fi
}

function compute_grub_default() {
    init_tests
    if [ ".$1" = "." ]; then
	V=$KERNEL_VERSION
    else
	V=$1
    fi
    
    menu=$(grep 'menuentry ' /boot/grub/grub.cfg  | grep -n $V| grep -v recovery |grep -v  upstart | cut -f 1 -d :)
    menu=$[menu-2]
    echo "1>$menu"
}

function get_packages() {
    sudo apt-get -y update
    sudo apt-get -y build-dep linux-image-$(uname -r) fakeroot
    sudo apt-get -y install make gcc emacs
}

function update_kernel () {
    _setup
    pushd $NOVA_CI_HOME
    git clone git@github.com:NVSL/linux-nova.git || (cd linux-nova; git pull)
    popd
}

function build_kernel () {
    _setup
    pushd $NOVA_CI_HOME
    #cp ../kernel/$(get_host_type).config ./linux-nova/.config
    sudo rm -rf *.tar.gz *.dsc *.deb *.changes
    (
	set -v;
	cd linux-nova;
	yes '' | make oldconfig
	make -j$[$(count_cpus) + 1] deb-pkg LOCALVERSION=-${K_SUFFIX};
	) 2>&1 | tee $R/kernel_build.log 
    popd
}

function install_kernel() {
    _setup

    (
	set -v;
	cd $NOVA_CI_HOME;
	sudo dpkg -i linux-image-${KERNEL_VERSION}_${KERNEL_VERSION}-?_amd64.deb &&
	sudo dpkg -i linux-headers-${KERNEL_VERSION}_${KERNEL_VERSION}-?_amd64.deb &&
	sudo dpkg -i linux-image-${KERNEL_VERSION}-dbg_${KERNEL_VERSION}-?_amd64.deb    
	) || false
    sudo update-grub
}

function reboot_to_nova() {
    echo Rebooting to $(compute_grub_default $1)...
    sudo grub-reboot $(compute_grub_default $1)
    sudo systemctl reboot -i
}


function build_module() {
    path=$1
    shift
    dest=$1
    shift
    files=$@
    V=0
    (set -v;
#     init_tests
     cd $NOVA_CI_HOME/linux-nova
     make V=$V LOCALVERSION=-${K_SUFFIX} prepare 
     make V=$V  LOCALVERSION=-${K_SUFFIX} modules_prepare 
     make V=$V  SUBDIRS=scripts/mod LOCALVERSION=-${K_SUFFIX}
     make V=$V  -j$[$(count_cpus) + 1] SUBDIRS=$path LOCALVERSION=-${K_SUFFIX}
     sudo cp $files /lib/modules/${KERNEL_VERSION}/kernel/$dest
     sudo depmod
    ) 2>&1 |tee $R/module_build.log

}

function build_image() {
    init_tests
    pushd $NOVA_CI_HOME
    (set -v;
     cd linux-nova;
     make LOCALVERSION=-nova bzImage
    ) 2>&1 |tee $R/bzimage_build.log
    popd
	
}

function install_image() {
    pushd $NOVA_CI_HOME
    (set -v;
     cd linux-nova;
     sudo cp  arch/x86/boot/bzImage /boot/vmlinuz-${KERNEL_VERSION}
     sudo update-grub
    ) 2>&1 |tee $R/bzimage_build.log
    popd
    
}

function build_nova() {
    build_module fs/nova fs fs/nova/nova.ko 
#    init_tests
#    pushd $NOVA_CI_HOME
#    (set -v;
#	cd linux-nova;
#	make LOCALVERSION=-${K_SUFFIX} prepare 
#	make LOCALVERSION=-${K_SUFFIX} modules_prepare 
#	make SUBDIRS=scripts/mod LOCALVERSION=-${K_SUFFIX}
#	make -j$[$(count_cpus) + 1] SUBDIRS=fs/nova LOCALVERSION=-${K_SUFFIX}
#	sudo cp fs/nova/nova.ko /lib/modules/${KERNEL_VERSION}/kernel/fs
#	sudo depmod
#	) 2>&1 |tee $R/module_build.log
#    popd

}

function build_and_reboot() {
    build_kernel
    if install_kernel; then
	reboot_to_nova
    else
	echo "Install failed"
    fi
}

function list_module_args() {
    if [ "." = "$1." ]; then
	modules=$(cat /proc/modules | cut -f 1 -d " ")
    else
	modules=$@
    fi
    for module in $modules; do 
	echo "$module ";
	if [ -d "/sys/module/$module/parameters" ]; then
	    ls /sys/module/$module/parameters/ | while read parameter; do
		echo -n "$parameter=";
		cat /sys/module/$module/parameters/$parameter;
	    done;
	fi;
	echo;
    done
}

function update_and_build_nova() {
    init_tests
    pushd $NOVA_CI_HOME
    if [ -d linux-nova ]; then
	cd linux-nova
	
	if git diff --name-only origin/master | grep -v fs/nova || 
	    ! [ -f /boot/vmlinuz-${KERNEL_VERSION}-* ]; then
	    echo Main kernel is out of date or missing
	    git diff --name-only origin/master
	    ls /boot/*
	    
	    git pull
	    build_kernel
	else
	    git pull
	    build_nova
	fi
    else
	echo Linux sources missing
	git clone git@github.com:NVSL/linux-nova.git
	if [ -d linux-nova ]; then
	    cd linux-nova
	    build_kernel
	else
	    echo git failed
	fi
    fi
    popd 
}

function umount_nova() {
    sudo umount $NOVA_CI_SECONDARY_FS
    sudo umount $NOVA_CI_PRIMARY_FS
}


function mount_one() {
    local dev=$1
    local dir=$2

    sudo mkdir -p $dir
    sudo mount -t NOVA -o init $dev $dir
}

function reload_dax() {
    sudo rmmod dax_pmem
    sudo rmmod device_dax

    sudo modprobe dax_pmem
    
}


function mount_nova() {

    umount_nova
    
    reload_nova 

    mount_one $NOVA_CI_PRIMARY_DEV $NOVA_CI_PRIMARY_FS
    mount_one $NOVA_CI_SECONDARY_DEV $NOVA_CI_SECONDARY_FS
}

function ktrace() {
    echo function > /sys/kernel/tracing/current_tracer;
    echo START > /sys/kernel/tracing/trace_marker;
    "$@" ;
    echo END > /sys/kernel/tracing/trace_marker;
    cat /sys/kernel/tracing/trace 
}

function remount_nova() {
    sudo umount $NOVA_CI_SECONDARY_FS
    sudo umount $NOVA_CI_PRIMARY_FS
    
    sudo mount -t NOVA $NOVA_CI_PRIMARY_DEV $NOVA_CI_PRIMARY_FS
    sudo mount -t NOVA $NOVA_CI_SECONDARY_DEV $NOVA_CI_SECONDARY_FS
}

function reload_nova() {

    args=$(python $NOVA_CI_HOME/jackal/NOVAConfigs.py $NOVA_MOUNT_OPTIONS)

    echo $args
    sudo modprobe libcrc32c
    sudo rmmod nova

    sudo modprobe nova $args  #nova_dbgmask=0xfffffff

    list_module_args nova
    
    sleep 1


}

function load_bisection() {
    umount_nova
    pushd $NOVA_CI_HOME/linux-nova/fs/nova;
    local dir=$NOVA_CI_HOME/bisect_modules
    sudo cp $dir/$1-*.ko /lib/modules/${KERNEL_VERSION}/kernel/fs/nova.ko
    sudo depmod
    popd
    reload_nova
}

function build_bisection () {
    set -v
    local dir=$NOVA_CI_HOME/bisect_modules
    mkdir -p $dir
    rm -rf $dir/*.{ko,build}

    pushd $NOVA_CI_HOME/linux-nova/fs/nova;
    local c=0;
    for i in $(git log $1 | grep ^commit | cut -f 2 -d ' ' |tac ); do
	local name=$(printf "%03d" $c)-$i
	echo $name
	(git checkout $i; build_nova) 2>&1 | tee $dir/$name.build;
	cp nova.ko $dir/$name.ko
	c=$[c+1]
    done
    popd
}

function start_dmesg_record() {
    stop_dmesg_record >/dev/null 2>&1 
    sudo dmesg -C
    sudo bash -c "(dmesg --follow & echo \$! > /tmp/dmesg_pid) | gzip -c > $1.gz &"
    DMESG_RECORDER=$(< /tmp/dmesg_pid)
}

function stop_dmesg_record() {
    sudo kill -9 "$DMESG_RECORDER" &
    true;
}

function dmesg_to_serial() {
    dmesg -w | sudo tee /dev/ttyS1 > /dev/null
}


function _do_run_tests() {
    
    (
	for i in $targets; do
	    (cd $i;
	     bug_report
	    # start_dmesg_record  ${NOVA_CI_LOG_DIR}/$i.dmesg
	     mount_nova 
	     bash -v ./go.sh $*
	     umount_nova
	     #stop_dmesg_record
	    ) 2>&1 | tee ${NOVA_CI_LOG_DIR}/$i.log
	    echo NOVA_CI_LOG: [${NOVA_CI_LOG_DIR}/$i.log]
	done
    ) 2>&1 | tee  $NOVA_CI_LOG_DIR/run_test.log

}

function do_run_tests() {
    new_result_dir
    echo "====================================" $NOVA_CI_LOG_DIR
    if [ ".$1" = "." ]; then
	targets=$(cat ${NOVA_CI_HOME}/tests_to_run.txt)
    else
	targets=$1
	shift
    fi

    _do_run_tests $*
}

function run_all() {

    init_tests
    if [ ".$1" = "." ]; then
	targets=$(cat ${NOVA_CI_HOME}/tests_to_run.txt)
    else
	targets=$1
	shift
    fi
    
    cat $NOVA_CI_HOME/configurations.txt   | while read  metadata_csum data_csum data_parity inplace_data_updates wprotect; do

	config=$(
	#echo -ne  "replica_metadata=$replica_metadata "
	echo -ne  "metadata_csum=$metadata_csum "
	echo -ne  "data_csum=$data_csum "
	echo -ne  "data_parity=$data_parity "
	echo -ne  "inplace_data_updates=$inplace_data_updates "
	#echo -ne  "unsafe_metadata=$unsafe_metadata "
	echo -ne  "wprotect=$wprotect\n")

	echo =================================================================
	echo $config
	echo =================================================================

	new_result_dir "${metadata_csum}-${data_csum}-${data_parity}-${inplace_data_updates}-${wprotect}"

	reload_nova $config

	_do_run_tests $*
    done
    
}

function ngrep() {
    (
	cd $NOVA_CI_HOME/linux-nova/fs/nova;
	find . -name '*.c' -o -name '*.h' | grep -v debian | xargs grep --color=always -n -A 2 -B 2  "$*" | less -S -R
    )
}
function lgrep() {
    (
	cd $NOVA_CI_HOME/linux-nova;
	find . -name '*.c' -o -name '*.h' | grep -v debian | xargs grep --color=always -n -A 2 -B 2  "$*" | less -S -R
    )
}

function auto_checkpatch() {
    ../../scripts/checkpatch.pl -f $1 --fix
    diff $1 $1.EXPERIMENTAL-checkpatch-fixes | less
    echo ok?
    read yn
    if [ "$yn." = "y." ]; then
	../../scripts/checkpatch.pl -f $1 --fix-inplace
    fi
}

function test_branch() {
    local branch=$1
    (
	set -e
	cd $NOVA_CI_HOME/linux-nova;
	git push --set-upstream origin $branch
	label=$branch-$(git log ${branch} -n 1 --pretty=format:%h)-$USER
	urls=$(for job in NOVA-build-one-off XFSTests-pass-one-off LTP-one-off; do
		   echo "http://35.199.145.104:8080/job/$job/buildWithParameters?token=aoeu&MY_GIT_TAG=$branch&RUN_LABEL=$label"
	       done)
	curl --user swanson $urls
    )
    
}
