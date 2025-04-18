#!/bin/bash
RED="\033[0;31m"
BLUE="\033[0;34m"

# Global variables
PCI_DEVICE=""
NUM_PORTS=""
HOST_TYPE=""
DELETE_FLAG=false

function print_usage() {
    echo "Usage: $0 [OPTIONS]"
    echo "Options:"
    echo "  -p, --pci PCI_DEVICE    PCI device address (required)"
    echo "  -n, --num NUM_PORTS     Number of ports to create (required for create)"
    echo "  -t, --type HOST_TYPE    Host type (src/dst) (required for create)"
    echo "  -d, --delete            Delete ports (no arguments)"
    echo "  -h, --help              Print this help message"
    echo ""
    echo "Examples:"
    echo "  $0 -p 0000:03:00.0 -n 2 -t src    Create 2 source ports"
    echo "  $0 -p 0000:03:00.0 -n 1 -t dst    Create 1 destination port"
    echo "  $0 -p 0000:03:00.0 -d             Delete all ports"
    exit 1
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -p|--pci)
            if [[ -z "$2" ]]; then
                echo "Error: -p/--pci requires PCI device address"
                print_usage
            fi
            PCI_DEVICE="$2"
            shift 2
            ;;
        -n|--num)
            if [[ -z "$2" ]]; then
                echo "Error: -n/--num requires number of ports"
                print_usage
            fi
            if ! [[ "$2" =~ ^[0-9]+$ ]]; then
                echo "Error: NUM_PORTS must be a number"
                print_usage
            fi
            NUM_PORTS="$2"
            shift 2
            ;;
        -t|--type)
            if [[ -z "$2" ]]; then
                echo "Error: -t/--type requires host type (src/dst)"
                print_usage
            fi
            if [[ "$2" != "src" && "$2" != "dst" ]]; then
                echo "Error: HOST_TYPE must be either 'src' or 'dst'"
                print_usage
            fi
            HOST_TYPE="$2"
            shift 2
            ;;
        -d|--delete)
            DELETE_FLAG=true
            shift
            ;;
        -h|--help)
            print_usage
            ;;
        *)
            echo "Error: Unknown option $1"
            print_usage
            ;;
    esac
done

# Validate arguments
if [ -z "$PCI_DEVICE" ]; then
    echo "Error: PCI device address is required"
    print_usage
fi

if $DELETE_FLAG; then
    if [ -n "$NUM_PORTS" ] || [ -n "$HOST_TYPE" ]; then
        echo "Error: --delete does not accept NUM_PORTS or HOST_TYPE"
        print_usage
    fi
else
    if [ -z "$NUM_PORTS" ] || [ -z "$HOST_TYPE" ]; then
        echo "Error: Both NUM_PORTS and HOST_TYPE are required for create"
        print_usage
    fi
fi

function usage(){
        echo -e "This script will Create or Remove VFIO Mediated devices \n"

	echo "	-h|--help 	    : Will show this help message"
	echo "	-r|--uuid_to_remove : 0000:03:00.0 to remove"
	echo "	-p|--pci_Device     : PCI Device of the physical function"
	echo "  -n|--num_mdev	    : Number of mdev to create, by default it's 1"
	echo
	echo "For Example Remove: create_remove_mdev.sh -r 0000:03:00.0 "
	echo "For Example Create: create_remove_mdev.sh -p 0000:03:00.0 -n 2"
       exit 1
}



#Function that run command on hosts
function run_cmd() {
	echo "      $@"
	    if ! eval "$@"; then
        	printf "\nFailed executing $@\n"
	        exit 1
	    fi
}


#function verify_mdev_enable_in_fw(){
#	local pci_device=$1
#	flag=$(mlxconfig -d $pci_device q |grep -iE "PER_PF_NUM_SF" | awk '{print$2}' | cut -d '(' -f1)
#	echo $flag
#}


#Get maximum number of Supported SFs by FW
#function get_maxmdev(){
#        cat /sys/class/net/$ifs/device/mdev_supported_types/mlx5_core-local/max_mdevs
#}


#Get the available_instances how many more mdev we can to create
#function get_available(){
#        cat /sys/class/net/$ifs/device/mdev_supported_types/mlx5_core-local/available_instances
#
#}

function get_ifs_by_pci(){
	local pci=$1
	ls /sys/bus/pci/devices/$pci/net/ | head -n 1
}


function unbind_bind(){
	local sf_core_mlx=$1

#	run_cmd "echo $sf_core_mlx > /sys/bus/auxiliary/drivers/mlx5_core.sf_cfg/unbind"
#	run_cmd "echo $sf_core_mlx > /sys/bus/auxiliary/drivers/mlx5_core.sf/bind"
}

function set_mac_addr(){
	local pci_sf=$1
	local physicalfn=$2
	local sf_num=$3
	local host_type=$4
	local mac_addr=""
	local mac1="94"
	local mac2="6d"
	local mac3="4d"
	local mac4
	local mac5
	local mac6

	# Calculate mac4 and mac5 based on sf_num
	mac4=$(printf "%02x" $((sf_num / 256)))
	mac5=$(printf "%02x" $((sf_num % 256)))

	# Set mac6 based on host_type
	if [ "$host_type" = "src" ]; then
		mac6="01"
	elif [ "$host_type" = "dst" ]; then
		mac6="02"
	else
		echo "Error: Invalid host_type. Must be 'src' or 'dst'"
		exit 1
	fi

	mac_addr="$mac1:$mac2:$mac3:$mac4:$mac5:$mac6"
	echo "mac_addr: $mac_addr  (host_type: $host_type)"

	run_cmd "devlink port function set $pci_sf hw_addr $mac_addr"
}

function active_sf(){
       local pci_sf=$1
       local physicalfn=$2
       local mac_addr=""
       run_cmd "devlink port function set $pci_sf state active"

}


#Get maximum number of Supported SFs:
function create_mdev(){
	local ifs=$1
	local mdevs=$2
	local pci_device=$3
	local host_type=$4
	#local new_uuid=""
	#local max_mdev=$(get_maxmdev)
	#local available_mdev=$(get_available)

	#	if [[ $mdevs -gt $max_mdev ]] ; then
	#		echo "There is not enough mdev in FW"
        #		exit 1
	#	elif [[ $mdevs -gt $available_mdev ]] ; then
	#		echo "There is not enough resources available in the system"
	#		echo "The available mdev's are $available_mdev and you request $mdevs"
	#		exit 1
	#	fi

     #Change Mode from legacy to switchdev
#     echo "Change the e-switch mode from legacy to switchdev and enable representors."

 #    if ls /sys/kernel/debug/mlx5/$pci_slot/compat/ > /dev/null 2>&1 ; then
#	   run_cmd "echo switchdev > /sys/kernel/debug/mlx5/$pci_slot/compat/mode"
 #    elif ls /sys/class/net/$ifs/compat/devlink/mode > /dev/null 2>&1 ; then
#	   run_cmd "echo switchdev > /sys/class/net/$ifs/compat/devlink/mode"
 #    else
  #         run_cmd "devlink dev eswitch set pci/$pci_slot mode switchdev"
   #  fi
    # echo

    # sleep 10

     port_number=$(echo $pci_device | awk '{print$1}' | cut -d ":" -f3 | cut -d "." -f2)

     for ((mdev=0; mdev<$mdevs ; mdev++)) ; do
	   echo "Creating new SF $((mdev+1))"
	   echo "devlink port add pci/$pci_device flavour pcisf pfnum $port_number sfnum $mdev controller 1"
	   result=$(devlink port add pci/$pci_device flavour pcisf pfnum $port_number sfnum $mdev controller 1)
	   pci_uniq=$(echo "$result" | cut -d' ' -f1 | sed 's/:$//')

           #mapp the pci sf to can get it pci/0000:11:00.0/32768
	   #first_st=$( mlxdevm port show | grep -i "pfnum $port_number sfnum $mdev"  | awk '{print$1}' | cut -d ":" -f1 )
	   #second_st=$( mlxdevm port show | grep -i "pfnum $port_number sfnum $mdev"  | awk '{print$1}' | cut -d ":" -f2 )
           #thread_st=$( mlxdevm port show | grep -i "pfnum $port_number sfnum $mdev"  | awk '{print$1}' | cut -d ":" -f3 )
           #pci_uniq=echo "$output" | cut -d' ' -f1 | sed 's/:$//'
           #pci_uniq="$first_st:$second_st:$thread_st"

	   echo "Set mac address for SF interface"
	       set_mac_addr $pci_uniq $ifs $mdev $host_type


	   echo "activate the SF interface"
	         active_sf  $pci_uniq

	   #echo "Unbind mdev from his own driver"
	   #sf_core=$(ls -l /sys/bus/auxiliary/devices/ | grep -i $pci_device | awk '{print$9}' | grep -i sf)
	   #for sf_core_number in $sf_core;do
	   #      number_sf=$(cat  /sys/bus/auxiliary/devices/$sf_core_number/sfnum)
		# if [[ $number_sf == $mdev ]];then
                 #   unbind_bind $sf_core_number

		# fi
	    #done
     done
     echo "done.."
}


# Function to remove mdev
function remove_mdev(){
	local pci_device="$1"
	output=$(devlink port show)
	pci_lines=$(echo "$output" | grep $pci_device | grep -o '^pci/[^ ]*' | sed 's/:$//')
	while IFS= read -r line; do
		   echo "Removing..."
		   run_cmd "devlink port del "$line""
		   echo "SF $line has been removed"
	done <<< "$pci_lines"
  exit 0;
}

# Main logic
if $DELETE_FLAG; then
    remove_mdev "$PCI_DEVICE"
else
    ifs=$(get_ifs_by_pci "$PCI_DEVICE")
    create_mdev "$ifs" "$NUM_PORTS" "$PCI_DEVICE" "$HOST_TYPE"
fi
