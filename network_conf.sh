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

function rep_intf_main() {
	rep_intf_get
	if [ $? -eq 0 ]; then
		rep_intf_show
	else
		echo "Failed to get interfaces"
	fi
}

# Run main function
rep_intf_main




