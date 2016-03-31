#!/bin/bash
# Copyright (C) 2012 Crowd9 Pty Ltd

usage ()
{
     echo >&2 "usage: bash $0 'john@example.com' 'MyBox' 'MyProvider.com' [\\\$20/mth]"
}

if [ $# -lt 3 ]
then
  usage
  exit 1
fi

rm sb.sh

HOST=$1
PLAN=$2
EMAIL=$3
COST=$4
PRIVATE=$5

echo "
###############################################################################
#               ServerBear (http://serverbear.com) benchmarker                #
###############################################################################

This script will:
  * Download and install packages to run UnixBench
  * Download and run UnixBench
  * Upload to ServerBear the UnixBench output and information about this computer

This script has been tested on Ubuntu, Debian, and CentOs (6+).  Running it on other environments may not work correctly.

To improve consistency, we recommend that you stop any services you may be running (e.g. web server, database, etc) to get the environment as close as possible to the original configuration.

WARNING: You run this script entirely at your own risk.
ServerBear accepts no responsibility for any damage this script may cause.

Please review the code at https://github.com/Crowd9/Benchmark if you have any concerns"

echo "Checking for required dependencies"

function requires() {
  if [ `$1 >/dev/null; echo $?` -ne 0 ]; then
    TO_INSTALL="$TO_INSTALL $2"
  fi 
}
function requires_command() { 
  requires "which $1" $1 
}

TO_INSTALL=""

if [ `which apt-get >/dev/null 2>&1; echo $?` -ne 0 ]; then
  PACKAGE_MANAGER='yum'

  requires 'yum list installed kernel-devel' 'kernel-devel'
  requires 'yum list installed libaio-devel' 'libaio-devel'
  requires 'yum list installed gcc-c++' 'gcc-c++'
  requires 'perl -MTime::HiRes -e 1' 'perl-Time-HiRes'
else
  PACKAGE_MANAGER='apt-get'
  MANAGER_OPTS='--fix-missing'
  UPDATE='apt-get update'

  requires 'dpkg -s build-essential' 'build-essential'
  requires 'dpkg -s libaio-dev' 'libaio-dev'
  requires 'perl -MTime::HiRes -e 1' 'perl'
fi

rm -rf sb-bench
mkdir -p sb-bench
cd sb-bench

requires_command 'gcc'
requires_command 'make'
requires_command 'curl'
requires_command 'traceroute'

if [ "`whoami`" != "root" ]; then
  SUDO='sudo'
fi

if [ "$TO_INSTALL" != '' ]; then
  echo "Using $PACKAGE_MANAGER to install$TO_INSTALL"
  if [ "$UPDATE" != '' ]; then
    echo "Doing package update"
    $SUDO $UPDATE
  fi 
  $SUDO $PACKAGE_MANAGER install -y $TO_INSTALL $MANAGER_OPTS
fi

PID=`cat ~/.sb-pid 2>/dev/null`
UNIX_BENCH_VERSION=5.1.3
UNIX_BENCH_DIR=UnixBench-$UNIX_BENCH_VERSION
IOPING_VERSION=0.6
IOPING_DIR=ioping-$IOPING_VERSION
FIO_VERSION=2.0.9
FIO_DIR=fio-$FIO_VERSION
UPLOAD_ENDPOINT='http://promozor.com/uploads.text'

# args: [name] [target dir] [filename] [url]
function require_download() {
  if ! [ -e "`pwd`/$2" ]; then
    echo "Downloading $1..."
    wget -q --no-check-certificate -O - $3 | tar -xzf -
  fi
}

require_download FIO fio-$FIO_DIR https://github.com/zmirc/Benchmark/raw/master/fio-$FIO_VERSION.tar.gz
require_download IOPing $IOPING_DIR https://github.com/zmirc/Benchmark/raw/master/ioping-$IOPING_VERSION.tar.gz
require_download UnixBench $UNIX_BENCH_DIR https://github.com/zmirc/Benchmark/raw/master/UnixBench$UNIX_BENCH_VERSION-patched.tgz
mv -f UnixBench $UNIX_BENCH_DIR 2>/dev/null

# http://linux.die.net/man/1/fio
cat > $FIO_DIR/reads.ini << EOF
[global]
randrepeat=1
ioengine=libaio
bs=64k
ba=64k
size=10G
direct=1
gtod_reduce=1
norandommap
iodepth=64
numjobs=1

[randomreads]
startdelay=0
filename=sb-io-test
readwrite=randread
EOF

cat > $FIO_DIR/writes.ini << EOF
[global]
randrepeat=1
ioengine=libaio
bs=64k
ba=64k
size=10G
direct=1
gtod_reduce=1
norandommap
iodepth=64
numjobs=1

[randomwrites]
startdelay=0
filename=sb-io-test
readwrite=randwrite
EOF

if [ -e "~/.sb-pid" ] && ps -p $PID >&- ; then
  echo "ServerBear job is already running (PID: $PID)"
  exit 0
fi

cat > run-upload.sh << EOF
#!/bin/bash

echo "
###############################################################################
#                                                                             #
#             Installation(s) complete.  Benchmarks starting...               #
#                                                                             #
#  Running Benchmark as a background task. This can take several hours.       #
#  ServerBear will email you when it's done.                                  #
#  You can log out/Ctrl-C any time while this is happening                    #
#  (it's running through nohup).                                              #
#                                                                             #
###############################################################################
"
>sb-output.log

echo "Checking server stats..."
echo "Distro:
\`cat /etc/issue 2>&1\`
CPU Info:
\`cat /proc/cpuinfo 2>&1\`
Disk space: 
\`df --total 2>&1\`
Free: 
\`free 2>&1\`" >> sb-output.log

echo "Running dd I/O benchmark..."

echo "dd 1Mx1k fdatasync: \`dd if=/dev/zero of=sb-io-test bs=1M count=1k conv=fdatasync 2>&1\`" >> sb-output.log
echo "dd 64kx16k fdatasync: \`dd if=/dev/zero of=sb-io-test bs=64k count=16k conv=fdatasync 2>&1\`" >> sb-output.log
echo "dd 1Mx1k dsync: \`dd if=/dev/zero of=sb-io-test bs=1M count=1k oflag=dsync 2>&1\`" >> sb-output.log
echo "dd 64kx16k dsync: \`dd if=/dev/zero of=sb-io-test bs=64k count=16k oflag=dsync 2>&1\`" >> sb-output.log

rm -f sb-io-test

echo "Running IOPing I/O benchmark..."
cd $IOPING_DIR
make >> ../sb-output.log 2>&1
echo "IOPing I/O: \`./ioping -c 10 . 2>&1 \`
IOPing seek rate: \`./ioping -RD . 2>&1 \`
IOPing sequential: \`./ioping -RL . 2>&1\`
IOPing cached: \`./ioping -RC . 2>&1\`" >> ../sb-output.log
cd ..

echo "Running FIO benchmark..."
cd $FIO_DIR
make >> ../sb-output.log 2>&1

echo "FIO random reads:
\`./fio reads.ini 2>&1\`
Done" >> ../sb-output.log

echo "FIO random writes:
\`./fio writes.ini 2>&1\`
Done" >> ../sb-output.log

rm sb-io-test 2>/dev/null
cd ..

# echo "Running traceroute..."
# echo "Traceroute (cachefly.cachefly.net): \`traceroute cachefly.cachefly.net 2>&1\`" >> sb-output.log

# echo "Running ping benchmark..."
# echo "Pings (cachefly.cachefly.net): \`ping -c 10 cachefly.cachefly.net 2>&1\`" >> sb-output.log

echo "Running UnixBench benchmark..."
cd $UNIX_BENCH_DIR
# ./Run -c 1 -c `grep -c processor /proc/cpuinfo` >> ../sb-output.log 2>&1
cd ..

# RESPONSE=\`curl -s -F "upload[upload_type]=unix-bench-output" -F "upload[data]=<sb-output.log" -F "upload[key]=$EMAIL|$HOST|$PLAN|$COST" -F "private=$PRIVATE" $UPLOAD_ENDPOINT\`

#echo "Uploading results..."
#echo "Response: \$RESPONSE"
#echo "Completed! Your benchmark has been queued & will be delivered in a jiffy."
kill -15 \`ps -p \$\$ -o ppid=\` &> /dev/null
# rm -rf ../sb-bench
rm -rf ~/.sb-pid

exit 0
EOF

chmod u+x run-upload.sh

>sb-script.log
nohup ./run-upload.sh >> sb-script.log 2>&1 & &> /dev/null

echo $! > ~/.sb-pid

tail -n 25 -F sb-script.log
