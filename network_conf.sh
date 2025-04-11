#!/bin/bash

# Global variables
rep_intfs=()
rep_intf_num=0

function usage() {
	exit 1
}

function rep_intf_init() {
	local name=$1
	local index=$2
	local hw_addr=$3
	local sfnum=$4
	echo "name=$name index=$index hw_addr=$hw_addr sfnum=$sfnum"
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

function ovs_br_create() {
	local i name

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
		# Extract name from rep_intf struct
		name=$(echo "${rep_intfs[$i]}" | awk -F'name=' '{print $2}' | awk '{print $1}')
		echo "Adding port $name to br0..."
		ovs-vsctl add-port br0 "$name"
		if [ $? -ne 0 ]; then
			echo "Error: Failed to add port $name to bridge br0"
			return 2
		fi
	done

	# Show OVS configuration
	echo -e "\nOVS bridge configuration:"
	ovs-vsctl show
	return 0
}

function ovs_br_delete() {
	local i name

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
		# Extract name from rep_intf struct
		name=$(echo "${rep_intfs[$i]}" | awk -F'name=' '{print $2}' | awk '{print $1}')
		echo "Deleting port $name from br0..."
		ovs-vsctl del-port br0 "$name"
		if [ $? -ne 0 ]; then
			echo "Warning: Failed to delete port $name from bridge br0"
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

function ovs_main() {
	# Create OVS bridge and add ports
	echo -e "\nCreating OVS bridge and adding ports..."
	ovs_br_create
	if [ $? -ne 0 ]; then
		echo "Failed to configure OVS bridge"
		return 1
	fi

	# Wait a bit before deleting
	sleep 2

	# Delete OVS bridge and ports
	echo -e "\nDeleting OVS bridge and ports..."
	ovs_br_delete
	if [ $? -ne 0 ]; then
		echo "Failed to delete OVS bridge"
		return 1
	fi

	return 0
}

function rep_intf_main() {
	rep_intf_get
	if [ $? -eq 0 ]; then
		rep_intf_show
		return 0
	else
		echo "Failed to get interfaces"
		return 1
	fi
}

# Run main functions in sequence
echo "=== Getting interface information ==="
rep_intf_main
echo -e "\n=== Testing OVS operations ==="
ovs_main




