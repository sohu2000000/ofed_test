#!/bin/bash

# Global variables
rep_intfs=()
rep_intf_num=0
PCI_ECPF0="0000:03:00.0"
CREATE_FLAG=false
NUM_PORTS=""
DELETE_FLAG=false
SHOW_FLAG=false
HOST_TYPE=""

function usage() {
	exit 1
}

function rep_intf_init() {
	local port_name=$1
	local sf_index=$2
	local hw_addr=$3
	local sfnum=$4
	echo "port_name=$port_name sf_index=$sf_index hw_addr=$hw_addr sfnum=$sfnum"
}

function rep_intf_get() {
	local line current_index current_name current_hw_addr idx=0
	local mlnx_sf_out devlink_out
	local current_sfnum

	# Clear the array first
	rep_intfs=()

	# Run mlnx-sf command and store output
	mlnx_sf_out=$(/sbin/mlnx-sf -a show)
	if [ $? -ne 0 ]; then
		echo "Error: Failed to run mlnx-sf command"
		return 1
	fi

	# Get devlink output
	devlink_out=$(devlink port show)
	if [ $? -ne 0 ]; then
		echo "Error: Failed to run devlink port show command"
		return 1
	fi

	# Process mlnx-sf output and store interfaces in array
	while IFS= read -r line; do
		if [[ $line =~ ^SF\ Index:\ (.+)$ ]]; then
			current_index="${BASH_REMATCH[1]}"
		elif [[ $line =~ ^[[:space:]]+Representor\ netdev:\ (.+)$ ]]; then
			current_name="${BASH_REMATCH[1]}"
		elif [[ $line =~ ^[[:space:]]+Function\ HWADDR:\ (.+)$ ]]; then
			current_hw_addr="${BASH_REMATCH[1]}"
			# Find sfnum from devlink output for current interface
			current_sfnum=""
			while IFS= read -r devlink_line; do
				if [[ $devlink_line =~ $current_name && $devlink_line =~ sfnum\ ([0-9]+) ]]; then
					current_sfnum="${BASH_REMATCH[1]}"
					break
				fi
			done <<< "$devlink_out"

			# If the port name is eth0, try to find the correct SF port name
			if [[ $current_name == "eth0" ]]; then
				while IFS= read -r devlink_line; do
					if [[ $devlink_line =~ sfnum\ $current_sfnum && $devlink_line =~ netdev\ (en3f0c1pf0sf[0-9]+) ]]; then
						current_name="${BASH_REMATCH[1]}"
						break
					fi
				done <<< "$devlink_out"
			fi

			rep_intfs[$idx]=$(rep_intf_init "$current_name" "$current_index" "$current_hw_addr" "$current_sfnum")
			((idx++))
		fi
	done <<< "$mlnx_sf_out"

	# Get the number of interfaces
	rep_intf_num=${#rep_intfs[@]}

	if [ $rep_intf_num -eq 0 ]; then
		echo "Warning: No interfaces found"
		return 2
	fi

	return 0
}

function rep_intf_show() {
	local i
	echo "Total number of SF interfaces: $rep_intf_num"
	for ((i=0; i<rep_intf_num; i++)); do
		echo "Interface struct $i: ${rep_intfs[$i]}"
	done
}

function rep_intf_del() {
	local i sf_index port_name

	echo "Deleting SF ports..."
	for ((i=0; i<rep_intf_num; i++)); do
		# Extract sf_index and port_name from rep_intf struct
		sf_index=$(echo "${rep_intfs[$i]}" | awk -F'sf_index=' '{print $2}' | awk '{print $1}')
		port_name=$(echo "${rep_intfs[$i]}" | awk -F'port_name=' '{print $2}' | awk '{print $1}')

		echo "Setting port $port_name to inactive state..."
		devlink port function set $port_name state inactive
		if [ $? -ne 0 ]; then
			echo "Warning: Failed to set port $port_name to inactive state"
		fi

		echo "Deleting port $port_name..."
		devlink port del $port_name
		if [ $? -ne 0 ]; then
			echo "Warning: Failed to delete port $port_name"
		fi
	done

	echo -e "\nCurrent port status:"
	devlink port show

	return 0
}

function rep_intf_create() {
	local script_dir=$(dirname "$0")
	local script_path="$script_dir/ext_create_remove_mdev_new_method_devlink.sh"
	local num_ports="$1"

	if [ -z "$num_ports" ]; then
		echo "Error: Number of ports not specified"
		return 1
	fi

	echo "Creating SF ports..."
	if [ ! -f "$script_path" ]; then
		echo "Error: Script $script_path not found"
		return 1
	fi

	# Make the script executable if it's not
	chmod +x "$script_path"

	# Execute the script to create SF ports
	echo "Running: $script_path -p $PCI_ECPF0 -n $num_ports"
	"$script_path" -p "$PCI_ECPF0" -n "$num_ports"
	if [ $? -ne 0 ]; then
		echo "Error: Failed to create SF ports"
		return 2
	fi

	# Show current port status
	echo -e "\nCurrent port status:"
	devlink port show

	return 0
}

function ovs_br_create() {
	local i port_name

	# Create OVS bridge br1
	echo "Creating OVS bridge br1..."
	ovs-vsctl add-br br1
	if [ $? -ne 0 ]; then
		echo "Error: Failed to create OVS bridge br1"
		return 1
	fi

	# Create OVS bridge br2
	echo "Creating OVS bridge br2..."
	ovs-vsctl add-br br2
	if [ $? -ne 0 ]; then
		echo "Error: Failed to create OVS bridge br2"
		return 1
	fi

	# Add ports to br1
	echo "Adding ports to br1..."
	for port in "p0" "pf0hpf"; do
		echo "Adding port $port to br1..."
		ovs-vsctl add-port br1 "$port"
		if [ $? -ne 0 ]; then
			echo "Error: Failed to add port $port to bridge br1"
			return 2
		fi
	done

	# Add ports to br2
	echo "Adding ports to br2..."
	for port in "p1" "pf1hpf"; do
		echo "Adding port $port to br2..."
		ovs-vsctl add-port br2 "$port"
		if [ $? -ne 0 ]; then
			echo "Error: Failed to add port $port to bridge br2"
			return 2
		fi
	done

	# Add SF ports to br1
	echo "Adding SF ports to bridge br1..."
	for ((i=0; i<rep_intf_num; i++)); do
		# Extract port_name from rep_intf struct
		port_name=$(echo "${rep_intfs[$i]}" | awk -F'port_name=' '{print $2}' | awk '{print $1}')
		echo "Adding port $port_name to br1..."
		ovs-vsctl add-port br1 "$port_name"
		if [ $? -ne 0 ]; then
			echo "Error: Failed to add port $port_name to bridge br1"
			return 2
		fi
	done

	# Show OVS configuration
	echo -e "\nOVS bridge configuration:"
	ovs-vsctl show
	return 0
}

function ovs_br_delete() {
	local bridges
	local ports
	local bridge
	local port

	# Get all existing OVS bridges
	bridges=$(ovs-vsctl list-br)
	if [ $? -ne 0 ]; then
		echo "Error: Failed to list OVS bridges"
		return 1
	fi

	# If no bridges exist, return
	if [ -z "$bridges" ]; then
		echo "No OVS bridges found"
		return 0
	fi

	echo "Found OVS bridges: $bridges"

	# For each bridge, delete all its ports
	for bridge in $bridges; do
		echo "Processing bridge: $bridge"

		# Get all ports in the current bridge
		ports=$(ovs-vsctl list-ports $bridge)
		if [ $? -ne 0 ]; then
			echo "Warning: Failed to list ports for bridge $bridge"
			continue
		fi

		# Delete each port from the bridge
		for port in $ports; do
			echo "Deleting port $port from bridge $bridge..."
			ovs-vsctl del-port $bridge "$port"
			if [ $? -ne 0 ]; then
				echo "Warning: Failed to delete port $port from bridge $bridge"
			fi
		done
	done

	# Delete all bridges
	for bridge in $bridges; do
		echo "Deleting bridge $bridge..."
		ovs-vsctl del-br $bridge
		if [ $? -ne 0 ]; then
			echo "Error: Failed to delete bridge $bridge"
			return 1
		fi
	done

	# Show final configuration
	echo -e "\nFinal OVS configuration:"
	ovs-vsctl show
	return 0
}

function print_usage() {
    echo "Usage: $0 [OPTIONS]"
    echo "Options:"
    echo "  --add, -a NUM_PORT HOST_TYPE    Add SF ports (HOST_TYPE must be 'src' or 'dst')"
    echo "  --delete, -d                    Delete SF ports and OVS bridge (no arguments)"
    echo "  --show, -s                      Show SF ports information (no arguments)"
    echo "  --help, -h                      Print this help message"
    echo ""
    echo "Examples:"
    echo "  $0 -a 2 src                     Add 2 source ports"
    echo "  $0 -a 1 dst                     Add 1 destination port"
    echo "  $0 -d                           Delete all ports"
    exit 1
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --add|-a)
            if [[ -z "$2" || -z "$3" ]]; then
                echo "Error: --add/-a requires two arguments: NUM_PORT and HOST_TYPE (src/dst)"
                print_usage
            fi
            if ! [[ "$2" =~ ^[0-9]+$ ]]; then
                echo "Error: NUM_PORT must be a number"
                print_usage
            fi
            if [[ "$3" != "src" && "$3" != "dst" ]]; then
                echo "Error: HOST_TYPE must be either 'src' or 'dst'"
                print_usage
            fi
            CREATE_FLAG=true
            NUM_PORTS="$2"
            HOST_TYPE="$3"
            shift 3
            ;;
        --delete|-d)
            if [[ -n "$2" && ! "$2" =~ ^- ]]; then
                echo "Error: --delete/-d does not accept arguments"
                print_usage
            fi
            DELETE_FLAG=true
            shift
            ;;
        --show|-s)
            if [[ -n "$2" && ! "$2" =~ ^- ]]; then
                echo "Error: --show/-s does not accept arguments"
                print_usage
            fi
            SHOW_FLAG=true
            shift
            ;;
        --help|-h)
            print_usage
            ;;
        *)
            echo "Error: Unknown option $1"
            print_usage
            ;;
    esac
done

# Validate arguments
if $CREATE_FLAG; then
    if [[ -z "$NUM_PORTS" || -z "$HOST_TYPE" ]]; then
        echo "Error: --add/-a requires both NUM_PORT and HOST_TYPE arguments"
        print_usage
    fi
fi

# Main logic
if $CREATE_FLAG; then
    rep_intf_create "$NUM_PORTS"
    if [ $? -ne 0 ]; then
        echo "Error: Failed to create SF ports"
        exit 1
    fi

    rep_intf_get
    if [ $? -eq 0 ]; then
        ovs_br_create
        if [ $? -ne 0 ]; then
            echo "Error: Failed to create OVS bridge"
            exit 1
        fi
    fi
elif $DELETE_FLAG; then
    rep_intf_get
    ovs_br_delete
    rep_intf_del
elif $SHOW_FLAG; then
    rep_intf_get
    if [ $? -eq 0 ]; then
        echo -e "\nSF ports information:"
        rep_intf_show
        echo -e "\nOVS bridge configuration:"
        ovs-vsctl show
    fi
else
    print_usage
fi




