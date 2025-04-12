#!/bin/bash

# Global variables
rep_intfs=()
rep_intf_num=0
PCI_ECPF0="0000:03:00.0"
CREATE_FLAG=false
NUM_PORTS=""
DELETE_FLAG=false
RUN_FLAG=false

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

	# Create OVS bridge br0
	echo "Creating OVS bridge br0..."
	ovs-vsctl add-br br0
	if [ $? -ne 0 ]; then
		echo "Error: Failed to create OVS bridge br0"
		return 1
	fi

	# Add additional ports
	echo "Adding additional ports to br0..."
	for port in "p0" "pf0hpf"; do
		echo "Adding port $port to br0..."
		ovs-vsctl add-port br0 "$port"
		if [ $? -ne 0 ]; then
			echo "Error: Failed to add port $port to bridge br0"
			return 2
		fi
	done

	# Add SF ports to the bridge
	echo "Adding SF ports to bridge br0..."
	for ((i=0; i<rep_intf_num; i++)); do
		# Extract port_name from rep_intf struct
		port_name=$(echo "${rep_intfs[$i]}" | awk -F'port_name=' '{print $2}' | awk '{print $1}')
		echo "Adding port $port_name to br0..."
		ovs-vsctl add-port br0 "$port_name"
		if [ $? -ne 0 ]; then
			echo "Error: Failed to add port $port_name to bridge br0"
			return 2
		fi
	done

	# Show OVS configuration
	echo -e "\nOVS bridge configuration:"
	ovs-vsctl show
	return 0
}

function ovs_br_delete() {
	local i port_name

	echo "Deleting ports from bridge br0..."

	# Delete additional ports
	for port in "p0" "pf0hpf"; do
		echo "Deleting port $port from br0..."
		ovs-vsctl del-port br0 "$port"
		if [ $? -ne 0 ]; then
			echo "Warning: Failed to delete port $port from bridge br0"
		fi
	done

	# Delete SF ports
	for ((i=0; i<rep_intf_num; i++)); do
		# Extract port_name from rep_intf struct
		port_name=$(echo "${rep_intfs[$i]}" | awk -F'port_name=' '{print $2}' | awk '{print $1}')
		echo "Deleting port $port_name from br0..."
		ovs-vsctl del-port br0 "$port_name"
		if [ $? -ne 0 ]; then
			echo "Warning: Failed to delete port $port_name from bridge br0"
		fi
	done

	# Delete the bridge
	echo "Deleting bridge br0..."
	ovs-vsctl del-br br0
	if [ $? -ne 0 ]; then
		echo "Error: Failed to delete bridge br0"
		return 1
	fi

	# Show final configuration
	echo -e "\nFinal OVS configuration:"
	ovs-vsctl show
	return 0
}

function print_usage() {
    echo "Usage: $0 [OPTIONS]"
    echo "Options:"
    echo "  --create, -c        Create SF ports (must be used with --num/-n)"
    echo "  --num, -n NUMBER    Specify number of SF ports to create (must be used with --create/-c)"
    echo "  --delete, -d        Delete SF ports and OVS bridge (no arguments)"
    echo "  --run, -r           Run the test (no arguments)"
    echo "  --help, -h          Print this help message"
    exit 1
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --create|-c)
            CREATE_FLAG=true
            shift
            ;;
        --num|-n)
            if [[ -z "$2" || ! "$2" =~ ^[0-9]+$ ]]; then
                echo "Error: --num/-n requires a valid number"
                print_usage
            fi
            NUM_PORTS="$2"
            shift 2
            ;;
        --delete|-d)
            if [[ -n "$2" && ! "$2" =~ ^- ]]; then
                echo "Error: --delete/-d does not accept arguments"
                print_usage
            fi
            DELETE_FLAG=true
            shift
            ;;
        --run|-r)
            if [[ -n "$2" && ! "$2" =~ ^- ]]; then
                echo "Error: --run/-r does not accept arguments"
                print_usage
            fi
            RUN_FLAG=true
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
if [[ -n "$NUM_PORTS" && ! $CREATE_FLAG ]]; then
    echo "Error: --num/-n must be used with --create/-c"
    print_usage
fi

if $CREATE_FLAG; then
    if [[ -z "$NUM_PORTS" ]]; then
        echo "Error: --create/-c requires --num/-n option"
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
elif $RUN_FLAG; then
    rep_intf_get
    if [ $? -eq 0 ]; then
        run_test
    fi
else
    print_usage
fi




