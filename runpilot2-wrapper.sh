#!/bin/bash
#
# pilot2 wrapper used at CERN central pilot factories
#
# https://google.github.io/styleguide/shell.xml

VERSION=20200528a-pilot2

function err() {
  dt=$(date --utc +"%Y-%m-%d %H:%M:%S,%3N [wrapper]")
  echo $dt $@ >&2
}

function log() {
  dt=$(date --utc +"%Y-%m-%d %H:%M:%S,%3N [wrapper]")
  echo $dt $@
}

function get_workdir {
  if [[ ${piloturl} == 'local' && ${harvesterflag} == 'false' ]]; then
    echo $(pwd)
    return 0
  fi

  if [[ ${harvesterflag} == 'true' ]]; then
    # test if Harvester WorkFlow is OneToMany aka "Jumbo" Jobs
    if [[ ${workflowarg} == 'OneToMany' ]]; then
      if [[ -n ${!harvesterarg} ]]; then
        templ=$(pwd)/panda_${!harvesterarg}
        mkdir ${templ}
        echo ${templ}
        return 0
      fi
    else
      echo $(pwd)
      return 0
    fi
  fi

  if [[ -n ${OSG_WN_TMP} ]]; then
    templ=${OSG_WN_TMP}/panda_XXXXXXXX
  elif [[ -n ${TMPDIR} ]]; then
    templ=${TMPDIR}/panda_XXXXXXXX
  else
    templ=$(pwd)/panda_XXXXXXXX
  fi
  temp=$(mktemp -d $templ)
  echo ${temp}
}


function check_python() {
  pybin=$(which python3 2>/dev/null || which python 2>/dev/null)
  if [[ $? -ne 0 ]]; then
    log "FATAL: python not found in PATH"
    err "FATAL: python not found in PATH"
    if [[ -z "${PATH}" ]]; then
      log "In fact, PATH env var is unset mon amie"
      err "In fact, PATH env var is unset mon amie"
    fi
    log "PATH content is ${PATH}"
    err "PATH content is ${PATH}"
    apfmon_fault 1
    sortie 1
  fi
    
  pyver=$($pybin -c "import sys; print('%03d%03d%03d' % sys.version_info[0:3])")
  # check if native python version > 2.6.0
  if [[ "${pyver}" > "002006000" ]] ; then
    log "Native python version is > 2.6.0 (${pyver})"
    log "Using ${pybin} for python compatibility"
  else
    log "ERROR: this site has native python < 2.6.0"
    err "ERROR: this site has native python < 2.6.0"
    log "Native python ${pybin} is old: ${pyver}"
  
    # Oh dear, we're doomed...
    log "FATAL: Failed to find a compatible python, exiting"
    err "FATAL: Failed to find a compatible python, exiting"
    apfmon_fault 1
    sortie 1
  fi
}

function check_proxy() {
  voms-proxy-info -all
  if [[ $? -ne 0 ]]; then
    log "WARNING: error running: voms-proxy-info -all"
    err "WARNING: error running: voms-proxy-info -all"
    arcproxy -I
    if [[ $? -eq 127 ]]; then
      log "FATAL: error running: arcproxy -I"
      err "FATAL: error running: arcproxy -I"
      apfmon_fault 1
      sortie 1
    fi
  fi
}


function setup_harvester_symlinks() {
  for datafile in `find ${HARVESTER_WORKDIR} -maxdepth 1 -type l -exec /usr/bin/readlink -e {} ';'`; do
      symlinkname=$(basename $datafile)
      ln -s $datafile $symlinkname
  done      
}


function check_vomsproxyinfo() {
  out=$(voms-proxy-info --version 2>/dev/null)
  if [[ $? -eq 0 ]]; then
    log "Check version: ${out}"
    return 0
  else
    log "voms-proxy-info not found"
    return 1
  fi
}

function check_arcproxy() {
  out=$(arcproxy --version 2>/dev/null)
  if [[ $? -eq 0 ]]; then
    log "Check version: ${out}"
    return 0
  else
    log "arcproxy not found"
    return 1
  fi
}

function pilot_cmd() {

  if [[ "X${harvester-datadir}" == "X" ]]; then
    opt-harvester-datadir=""
  else
    opt-harvester-datadir="--harvester-datadir ${harvester-datadir}"
  fi
  cmd="${pybin} pilot2/pilot.py -q ${qarg} -i ${iarg} -j ${jarg} ${opt-harvester-datadir} --pilot-user=generic ${pilotargs}"
  # test if not harvester job and running OneToMany Harvester workflow (aka Jumbo Jobs)
  if [[ ${harvesterflag} == 'true' ]] && [[ ${workflowarg} == 'OneToMany' ]] && [ -z ${HARVESTER_PILOT_WORKDIR+x} ] ; then
     # The option x was added in pilot2-2.12.4.7
     # set the maximum failures on getjob
     # 
     cmd="$cmd -x 3 -a ${HARVESTER_PILOT_WORKDIR}"
  fi
  echo ${cmd}
}

function get_piloturl() {

  local version=$1
  local pilotdir=file:///cvmfs/atlas.cern.ch/repo/sw/PandaPilot/tar

  if [[ -n ${piloturl} ]]; then
    echo ${piloturl}
    return 0
  fi

  if [[ ${version} == '1' ]]; then
    log "FATAL: pilot version 1 requested, not supported by this wrapper"
    err "FATAL: pilot version 1 requested, not supported by this wrapper"
    apfmon 1
    sortie 1
  elif [[ ${version} == '2' ]]; then
    pilottar=${pilotdir}/pilot2.tar.gz
  elif [[ ${version} == 'latest' ]]; then
    pilottar=${pilotdir}/pilot2.tar.gz
  elif [[ ${version} == 'current' ]]; then
    pilottar=${pilotdir}/pilot2.tar.gz
  else
    pilottar=${pilotdir}/pilot2-${version}.tar.gz
  fi
  echo ${pilottar}
}

function get_pilot() {

  local url=$1

  if [[ ${harvesterflag} == 'true' ]] && [[ ${workflowarg} == 'OneToMany' ]]; then
    cp -v ${HARVESTER_WORK_DIR}/pilot2.tar.gz .
  fi

  if [[ ${url} == 'local' ]]; then
    log "piloturl=local so download not needed"
    if [[ -f pilot2.tar.gz ]]; then
      log "local tarball pilot2.tar.gz exists OK"
      tar -xzf pilot2.tar.gz
      if [[ $? -ne 0 ]]; then
        log "ERROR: pilot extraction failed for pilot2.tar.gz"
        err "ERROR: pilot extraction failed for pilot2.tar.gz"
        return 1
      fi
    else
      log "local pilot2.tar.gz not found so assuming already extracted"
    fi
  else
    curl --connect-timeout 30 --max-time 180 -sSL ${url} | tar -xzf -
    if [[ ${PIPESTATUS[0]} -ne 0 ]]; then
      log "ERROR: pilot download failed: ${url}"
      err "ERROR: pilot download failed: ${url}"
      return 1
    fi
  fi

  if [[ -f pilot2/pilot.py ]]; then
    log "File pilot2/pilot.py exists OK"
    log "pilot2/PILOTVERSION: $(cat pilot2/PILOTVERSION)"
    return 0
  else
    log "ERROR: pilot2/pilot.py not found"
    err "ERROR: pilot2/pilot.py not found"
    return 1
  fi
}

function muted() {
  log "apfmon messages muted"
}

function apfmon_running() {
  [[ ${mute} == 'true' ]] && muted && return 0
  echo -n "running 0 ${VERSION} ${qarg} ${APFFID}:${APFCID}" > /dev/udp/148.88.67.14/28527
  out=$(curl -ksS --connect-timeout 10 --max-time 20 -d uuid=${UUID} \
             -d qarg=${qarg} -d state=wrapperrunning -d wrapper=${VERSION} \
             -d gtag=${GTAG} -d hid=${HARVESTER_ID} -d hwid=${HARVESTER_WORKER_ID} \
             ${APFMON}/jobs/${APFFID}:${APFCID})
  if [[ $? -eq 0 ]]; then
    log $out
  else
    err "WARNING: wrapper monitor ${UUID}"
  fi
}

function apfmon_exiting() {
  [[ ${mute} == 'true' ]] && muted && return 0
  out=$(curl -ksS --connect-timeout 10 --max-time 20 \
             -d state=wrapperexiting -d rc=$1 -d uuid=${UUID} \
             -d ids="${pandaids}" -d duration=$2 \
             ${APFMON}/jobs/${APFFID}:${APFCID})
  if [[ $? -eq 0 ]]; then
    log $out
  else
    err "WARNING: wrapper monitor ${UUID}"
  fi
}

function apfmon_fault() {
  [[ ${mute} == 'true' ]] && muted && return 0

  out=$(curl -ksS --connect-timeout 10 --max-time 20 \
             -d state=wrapperfault -d rc=$1 -d uuid=${UUID} \
             ${APFMON}/jobs/${APFFID}:${APFCID})
  if [[ $? -eq 0 ]]; then
    log $out
  else
    err "WARNING: wrapper monitor ${UUID}"
  fi
}

function trap_handler() {
  log "Caught $1, signalling pilot PID: $pilotpid"
  kill -s $1 $pilotpid
  wait
}

function sortie() {
  ec=$1
  if [[ $ec -eq 0 ]]; then
    state=wrapperexiting
  else
    state=wrapperfault
  fi

  log "==== wrapper stdout END ===="
  err "==== wrapper stderr END ===="

  duration=$(( $(date +%s) - ${starttime} ))
  log "${state} ec=$ec, duration=${duration}"
  
  if [[ ${mute} == 'true' ]]; then
    muted
  else
    echo -n "${state} ${duration} ${VERSION} ${qarg} ${APFFID}:${APFCID}" > /dev/udp/148.88.67.14/28527
  fi

  exit $ec
}


function main() {
  #
  # Fail early, fail often^W with useful diagnostics
  #

  echo "This is PanDA pilot2 wrapper version: $VERSION"
  echo "Please send development requests to p.love@lancaster.ac.uk"

  log "==== wrapper stdout BEGIN ===="
  err "==== wrapper stderr BEGIN ===="
  UUID=$(cat /proc/sys/kernel/random/uuid)
  apfmon_running
  echo

  echo "---- Host details ----"
  echo "hostname:" $(hostname -f)
  echo "pwd:" $(pwd)
  echo "whoami:" $(whoami)
  echo "id:" $(id)
  echo "getopt:" $(getopt -V 2>/dev/null)
  if [[ -r /proc/version ]]; then
    echo "/proc/version:" $(cat /proc/version)
  fi
  echo "lsb_release:" $(lsb_release -d 2>/dev/null)
  
  myargs=$@
  echo "wrapper call: $0 $myargs"

  cpuinfo_flags="flags: EMPTY"
  if [ -f /proc/cpuinfo ]; then
    cpuinfo_flags="$(grep '^flags' /proc/cpuinfo 2>/dev/null | sort -u 2>/dev/null)"
    if [ -z "${cpuinfo_flags}" ]; then 
      cpuinfo_flags="flags: EMPTY"
    fi
  else
    cpuinfo_flags="flags: EMPTY"
  fi
  
  echo "Flags from /proc/cpuinfo:"
  echo ${cpuinfo_flags}
  echo

  
  echo "---- Enter workdir ----"
  workdir=$(get_workdir)
  if [[ -f pandaJobData.out ]]; then
    log "Copying job description to working dir"
    cp pandaJobData.out $workdir/pandaJobData.out
  fi
  log "cd ${workdir}"
  cd ${workdir}
  if [[ ${harvesterflag} == 'true' ]]; then
        export HARVESTER_PILOT_WORKDIR=${workdir}
        log "Define HARVESTER_PILOT_WORKDIR : ${HARVESTER_PILOT_WORKDIR}"
  fi
  echo
  
  echo "---- Retrieve pilot code ----"
  url=$(get_piloturl ${pilotversion})
  log "Using piloturl: ${url}"

  get_pilot ${url}
  if [[ $? -ne 0 ]]; then
    log "FATAL: failed to get pilot code"
    err "FATAL: failed to get pilot code"
    apfmon_fault 1
    sortie 1
  fi
  echo
  
  echo "---- Initial environment ----"
  printenv | sort
  echo

  ## added on 200804 by FaHui, for DOMA
  echo "---- for DOMA, cache files ----"
  rse=GKE-LSST_LOGS
  # queuedata_json_url="http://ai-idds-01.cern.ch:25080/cache/schedconfig/${sarg}.all.json"
  queuedata_json_url="https://datalake-cric.cern.ch/api/atlas/pandaqueue/query/?json&pandaqueue=${sarg}"
  curl -k --connect-timeout 30 --max-time 180 -sSL ${queuedata_json_url} > cric_pandaqueues.json
  curl -k --connect-timeout 30 --max-time 180 -sSL "https://datalake-cric.cern.ch/api/atlas/pandaqueue/query/?json" > queuedata.json
  curl -k --connect-timeout 30 --max-time 180 -sSL "https://datalake-cric.cern.ch/api/atlas/ddmendpoint/query/?json&ddmendpoint=$rse" > cric_ddmendpoints.json
  export PILOT_HOME=`pwd`
  ls -l *.json
  echo
  
  echo "---- Shell process limits ----"
  ulimit -a
  echo
  
  echo "---- Check python version ----"
  check_python
  echo

  if [[ ${harvesterflag} == 'true' ]]; then
    echo "---- Create symlinks to input data ----"
    log 'Create to symlinks to input data from harvester info'
    setup_harvester_symlinks
    echo
  fi
    
  if [[ "${shoalflag}" == 'true' ]]; then
    echo "--- Setup shoal ---"
    setup_shoal
    echo
  fi

  echo "---- Proxy Information ----"
  if [[ ${tflag} == 'true' ]]; then
    log 'Skipping proxy checks due to -t flag'
  else
    check_proxy
  fi
  echo
  
  echo "---- JOB Environment ----"
  printenv | sort
  echo

  echo "---- Build pilot cmd ----"
  cmd=$(pilot_cmd)
  # cmd="$cmd -a $workdir"
  echo cmd: ${cmd}
  echo

  echo "---- Ready to run pilot ----"
  trap trap_handler SIGTERM SIGQUIT SIGSEGV SIGXCPU SIGUSR1 SIGBUS
  echo

  log "==== pilot stdout BEGIN ===="
  $cmd &
  pilotpid=$!
  log "pilotpid: $pilotpid"
  wait $pilotpid
  pilotrc=$?
  log "==== pilot stdout END ===="
  log "==== wrapper stdout RESUME ===="
  log "Pilot exit status: $pilotrc"
  
  if [[ -f ${workdir}/pilot2/pandaIDs.out ]]; then
    # max 30 pandaids
    pandaids=$(cat ${workdir}/pilot2/pandaIDs.out | xargs echo | cut -d' ' -f-30)
    log "pandaids: ${pandaids}"
  else
    log "File not found: ${workdir}/pilot2/pandaIDs.out, no payload"
    err "File not found: ${workdir}/pilot2/pandaIDs.out, no payload"
    pandaids=''
  fi

  duration=$(( $(date +%s) - ${starttime} ))
  apfmon_exiting ${pilotrc} ${duration}
  

  if [[ ${piloturl} != 'local' ]]; then
      log "cleanup: rm -rf $workdir"
      rm -fr $workdir
  else 
      log "Test setup, not cleaning"
  fi

  sortie 0
}

function usage () {
  echo "Usage: $0 -q <queue> -r <resource> -s <site> [<pilot_args>]"
  echo
  echo "  --container (Standalone container), file to source for release setup "
  echo "  --harvester (Harvester at HPC edge), NodeID from HPC batch system "
  echo "  -i,   pilot type, default PR"
  echo "  -j,   job type prodsourcelabel, default 'managed'"
  echo "  -q,   panda queue"
  echo "  -r,   panda resource"
  echo "  -s,   sitename for local setup"
  echo "  --piloturl, URL of pilot code tarball"
  echo "  --pilotversion, request particular pilot version"
  echo
  exit 1
}

starttime=$(date +%s)

# wrapper args are explicit if used in the wrapper
# additional pilot2 args are passed as extra args
containerflag='false'
containerarg=''
harvesterflag='false'
harvesterarg=''
harvester-datadir=''
workflowarg=''
iarg='PR'
jarg='managed'
qarg=''
rarg=''
shoalflag=false
tflag='false'
piloturl=''
pilotversion='latest'
mute='false'
myargs="$@"

POSITIONAL=()
while [[ $# -gt 0 ]]
do
key="$1"
case $key in
    -h|--help)
    usage
    shift
    shift
    ;;
    --container)
    containerflag='true'
    #containerarg="$2"
    #shift
    shift
    ;;
    --harvester)
    harvesterflag='true'
    harvesterarg="$2"
    mute='true'
    piloturl='local'
    shift
    shift
    ;;
    --harvester_workflow)
    harvesterflag='true'
    workflowarg="$2"
    shift
    shift
    ;;
    --harvester-datadir)
    harvester-datadir="$2"
    shift
    shift
    ;;
    --mute)
    mute='true'
    shift
    ;;
    --pilotversion)
    pilotversion="$2"
    shift
    shift
    ;;
    --piloturl)
    piloturl="$2"
    shift
    shift
    ;;
    -i)
    iarg="$2"
    shift
    shift
    ;;
    -j)
    jarg="$2"
    shift
    shift
    ;;
    -q)
    qarg="$2"
    shift
    shift
    ;;
    -r)
    rarg="$2"
    shift
    shift
    ;;
    -s)
    sarg="$2"
    shift
    shift
    ;;
    -S|--shoal)
    shoalflag=true
    shift
    ;;
    -t)
    tflag='true'
    POSITIONAL+=("$1") # save it in an array for later
    shift
    ;;
    *)
    POSITIONAL+=("$1") # save it in an array for later
    shift
    ;;
esac
done
set -- "${POSITIONAL[@]}" # restore positional parameters

if [ -z "${qarg}" ]; then usage; exit 1; fi

pilotargs="$@"

fabricmon="http://fabricmon.cern.ch/api"
fabricmon="http://apfmon.lancs.ac.uk/api"
if [ -z ${APFMON} ]; then
  APFMON=${fabricmon}
fi
main "$myargs"
