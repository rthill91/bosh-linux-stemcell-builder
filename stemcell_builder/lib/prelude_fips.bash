# do nothing if the variant isn't fips
if [ ${stemcell_operating_system_variant} != "fips" ]; then
    echo "Skipping base_apt_fips given that this is not a 'fips' variant"
    exit 0
else
    echo "FIPS variant detected. setting up FIPS"
fi

if [ -z ${UBUNTU_ADVANTAGE_TOKEN} ]; then
    echo "'fips' variant detected but \$UBUNTU_ADVANTAGE_TOKEN not given."
    echo "please provide a UBUNTU_ADVANTAGE_TOKEN to be able to build 'fips' variants."
    exit 1
fi

function ua_attach() {
    echo "Setting up Ubuntu Advantage ..."

    DEBIAN_FRONTEND=noninteractive run_in_chroot ${chroot} "apt-get install --assume-yes ubuntu-advantage-tools"

    run_in_chroot ${chroot} "ua attach --no-auto-enable ${UBUNTU_ADVANTAGE_TOKEN}"
}


function ua_detach() {
    run_in_chroot_without_apt ${chroot} "ua detach --assume-yes"

    # cleanup (to not leak the token into an image)
    run_in_chroot ${chroot} "rm -rf /var/lib/ubuntu-advantage/private/*"
    run_in_chroot ${chroot} "rm /var/log/ubuntu-advantage.log"
}

function ua_enable_fips() {
    run_in_chroot_without_apt ${chroot} "ua enable --assume-yes fips-preview"
}

function run_in_chroot_without_apt() {
    local chroot=${1}
    local script=${2}

    run_in_chroot ${chroot} "mv /usr/bin/apt-get /usr/bin/apt-get.back"
    run_in_chroot ${chroot} "ln -s /usr/bin/true /usr/bin/apt-get"
    run_in_chroot ${chroot} "${script}"
    run_in_chroot ${chroot} "rm /usr/bin/apt-get"
    run_in_chroot ${chroot} "mv /usr/bin/apt-get.back /usr/bin/apt-get"
}

function write_fips_cmdline_conf() {
    cat << "EOF" >> "${chroot}/etc/default/grub.d/99-fips.cfg"
GRUB_CMDLINE_LINUX_DEFAULT="$GRUB_CMDLINE_LINUX_DEFAULT fips=1"
EOF
}


# taken from https://git.launchpad.net/livecd-rootfs/tree/live-build/ubuntu-cpc/hooks.d/chroot/999-cpc-fixes.chroot#n125
psuedo_grub_probe() {
   cat <<"PSUEDO_GRUB_PROBE"
#!/bin/sh
Usage() {
   cat <<EOF
Usage: euca-psuedo-grub-probe
   this is a wrapper around grub-probe to provide the answers for an ec2 guest
EOF
}
bad_Usage() { Usage 1>&2; fail "$@"; }

short_opts=""
long_opts="device-map:,target:,device"
getopt_out=$(getopt --name "${0##*/}" \
   --options "${short_opts}" --long "${long_opts}" -- "$@") &&
   eval set -- "${getopt_out}" ||
   bad_Usage

device_map=""
target=""
device=0
arg=""

while [ $# -ne 0 ]; do
   cur=${1}; next=${2};
   case "$cur" in
      --device-map) device_map=${next}; shift;;
      --device) device=1;;
      --target) target=${next}; shift;;
      --) shift; break;;
   esac
   shift;
done
arg=${1}

case "${target}:${device}:${arg}" in
   device:*:/*) echo "/dev/sda1"; exit 0;;
   fs:*:*) echo "ext2"; exit 0;;
   partmap:*:*)
      # older versions of grub (lucid) want 'part_msdos' written
      # rather than 'msdos'
      legacy_pre=""
      grubver=$(dpkg-query --show --showformat '${Version}\n' grub-pc 2>/dev/null) &&
         dpkg --compare-versions "${grubver}" lt 1.98+20100804-5ubuntu3 &&
         legacy_pre="part_"
      echo "${legacy_pre}msdos";
      exit 0;;
   abstraction:*:*) echo ""; exit 0;;
   drive:*:/dev/sda) echo "(hd0)";;
   drive:*:/dev/sda*) echo "(hd0,1)";;
   fs_uuid:*:*) exit 1;;
esac
PSUEDO_GRUB_PROBE
}


function mock_grub_probe() {
    # make sure /usr/sbin/grub-probe is installed in the chroot
    DEBIAN_FRONTEND=noninteractive run_in_chroot ${chroot} "apt-get install --assume-yes grub-common"
    gprobe="${chroot}/usr/sbin/grub-probe"
    if [ -f "${gprobe}" ]; then
        mv "${gprobe}" "${gprobe}.dist"
    fi
    psuedo_grub_probe > "${gprobe}"
    chmod 755 "${gprobe}"
}


function unmock_grub_probe() {
    gprobe="${chroot}/usr/sbin/grub-probe"
    if [ -f "${gprobe}.dist" ]; then
        mv "${gprobe}.dist" "${gprobe}"
    fi
}
