#!/bin/bash
RED="\033[0;31m"
BLUE="\033[0;34m"


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
	local mac_addr=""

	pre_mac=$(cat /sys/class/net/$physicalfn/address | cut -d: -f1-2)

                for i in {1..4}; do
                random_2_chars=`cat /dev/urandom | tr -dc 'a-f0-9' | fold -w 2 | head -1`
                mac_addr="$mac_addr:$random_2_chars"
                done
                mac_addr="$pre_mac$mac_addr"

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
	       set_mac_addr $pci_uniq $ifs


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

	echo
	done

echo done..

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

#Main

if [[ -z $1 ]] ; then usage ; exit 1 ; fi
if [[ -n $1 ]] && [[ -z $2 ]] ; then usage ; exit 1 ; fi

#Check flags arguments
while [[ $# -gt 0 ]]
 do
        key="$1"

 case $key in
    -p|--pci_device)
    pci_device="$2"
    shift # past argument
    ;;

    -n|--num_mdev)
    mdev=${2:-1}
    shift # past argument
    ;;

    -r|--pci_device)
    pci_device="$2"
    shift #past argument
    remove_mdev $pci_device
	#Remove uuid configured
    ;;

    -h|--help|*)
	echo "Error, unsupported parameter: $1"
        usage
        exit 1
            # unknown option
    ;;

 esac
 shift # past argument or value
done


#get_fw_state=$(verify_mdev_enable_in_fw $pci_device)
#if [ "$get_fw_state" != "True" ]; then
#        echo "The PER_PF_NUM_SF flag is Disabled in the FW please Enable it before."
#        exit
#fi


ifs=$(get_ifs_by_pci $pci_device)

#Go to Create.

create_mdev $ifs $mdev $pci_device
