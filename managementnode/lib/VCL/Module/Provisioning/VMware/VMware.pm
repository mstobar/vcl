#!/usr/bin/perl -w
###############################################################################
# $Id$
###############################################################################
# Licensed to the Apache Software Foundation (ASF) under one or more
# contributor license agreements.  See the NOTICE file distributed with
# this work for additional information regarding copyright ownership.
# The ASF licenses this file to You under the Apache License, Version 2.0
# (the "License"); you may not use this file except in compliance with
# the License.  You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
###############################################################################

=head1 NAME

VCL::Provisioning::VMware::Vmware

=head1 SYNOPSIS

 Needs to be written

=head1 DESCRIPTION

 This module provides VCL support for VMWare
 http://www.vmware.com

=cut

##############################################################################
package VCL::Module::Provisioning::VMware::VMware;

# Specify the lib path using FindBin
use FindBin;
use lib "$FindBin::Bin/../../../..";

# Configure inheritance
use base qw(VCL::Module::Provisioning);

# Specify the version of this module
our $VERSION = '2.00';

# Specify the version of Perl to use
use 5.008000;

use strict;
use warnings;
use diagnostics;
use English qw( -no_match_vars );
use IO::File;
use Fcntl qw(:DEFAULT :flock);
use File::Temp qw( tempfile );

use VCL::utils;

use VCL::Module::Provisioning::VMware::vSphere_SDK;
use VCL::Module::Provisioning::VMware::VIX_API;

##############################################################################

=head1 CLASS VARIABLES

=cut

=head2 %VM_OS_CONFIGURATION

 Data type   : hash
 Description : Maps OS names to the appropriate guestOS and Ethernet virtualDev
               values to be used in the vmx file.

=cut

our %VM_OS_CONFIGURATION = (
	# Linux configurations:
	"linux-x86" => {
		"guestOS" => "otherlinux",
		"ethernet-virtualDev" => "vlance",
	},
	"linux-x86_64" => {
		"guestOS" => "otherlinux-64",
		"ethernet-virtualDev" => "e1000",
	},
	# Windows configurations:
	"xp-x86" => {
		"guestOS" => "winXPPro",
		"ethernet-virtualDev" => "vlance",
	},
	"xp-x86_64" => {
		"guestOS" => "winXPPro-64",
		"ethernet-virtualDev" => "e1000",
	},
	"vista-x86" => {
		"guestOS" => "winvista",
		"ethernet-virtualDev" => "e1000",
	},
	"vista-x86_64" => {
		"guestOS" => "winvista-64",
		"ethernet-virtualDev" => "e1000",
	}, 
	"7-x86" => {
		"guestOS" => "winvista",
		"ethernet-virtualDev" => "e1000",
	},
	"7-x86_64" => {
		"guestOS" => "winvista-64",
		"ethernet-virtualDev" => "e1000",
	}, 
	"2003-x86" => {
		"guestOS" => "winNetEnterprise",
		"ethernet-virtualDev" => "vlance",
	},
	"2003-x86_64" => {
		"guestOS" => "winNetEnterprise-64",
		"ethernet-virtualDev" => "e1000",
	},
	"2008-x86" => {
		"guestOS" => "winServer2008Enterprise-32",
		"ethernet-virtualDev" => "e1000",
	},
	"2008-x86_64" => {
		"guestOS" => "winServer2008Enterprise-64",
		"ethernet-virtualDev" => "e1000",
	},
	# Default Windows configuration if Windows version isn't found above:
	"windows-x86" => {
		"guestOS" => "winXPPro",
		"ethernet-virtualDev" => "vlance",
	},
	"windows-x86_64" => {
		"guestOS" => "winXPPro-64",
		"ethernet-virtualDev" => "e1000",
	},
	# Default configuration if OS is not Windows or Linux:
	"default-x86" => {
		"guestOS" => "other",
		"ethernet-virtualDev" => "vlance",
	},
	"default-x86_64" => {
		"guestOS" => "other-64",
		"ethernet-virtualDev" => "e1000",
	},
);

=head2 $VSPHERE_SDK_PACKAGE

 Data type   : string
 Description : Perl package name for the vSphere SDK module.

=cut

our $VSPHERE_SDK_PACKAGE = 'VCL::Module::Provisioning::VMware::vSphere_SDK';

=head2 $VIX_API_PACKAGE

 Data type   : string
 Description : Perl package name for the VIX API module.

=cut

our $VIX_API_PACKAGE = 'VCL::Module::Provisioning::VMware::VIX_API';

##############################################################################

=head1 OBJECT METHODS

=cut

#/////////////////////////////////////////////////////////////////////////////

=head2 initialize

 Parameters  : none
 Returns     : boolean
 Description : Determines how the VM and VM host can be contolled. Creates an
               API object which is used to control the VM throughout the
               reservation. Creates a VM host OS object to be used to control
               the VM host throughout the reservation.

=cut

sub initialize {
	my $self = shift;
	if (ref($self) !~ /vmware/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}
	
	my $vmhost_data = $self->get_vmhost_datastructure() || return;
	my $vmhost_computer_name = $vmhost_data->get_computer_node_name() || return;
	my $vm_computer_name = $self->data->get_computer_node_name() || return;
	
	my $vmware_api;
	my $vmhost_os;
	
	# Create an API object which will be used to control the VM (register, power on, etc.)
	if (($vmware_api = $self->get_vsphere_sdk_object()) && !$vmware_api->is_restricted()) {
		notify($ERRORS{'DEBUG'}, 0, "vSphere SDK object will be used to control the VM: $vm_computer_name, and to control the OS of the VM host: $vmhost_computer_name");
		$vmhost_os = $vmware_api;
	}
	elsif (($vmware_api = $self->get_vix_api_object()) && !$vmware_api->is_restricted()) {
		notify($ERRORS{'DEBUG'}, 0, "VIX API object will be used to control the VM: $vm_computer_name");
	}
	# Add code here to create an API object to control free ESXi via SSH once the utility module has been implemented
	# elsif (...) {
	# }
	else {
		notify($ERRORS{'WARNING'}, 0, "failed to create an API object to control the VM: $vm_computer_name");
		return;
	}
	
	# Create a VM host OS object if the vSphere SDK can't be used to control the VM host OS
	if (!$vmhost_os) {
		# Get a DataStructure object containing the VM host's data and get the VM host OS module Perl package name
		my $vmhost_image_name = $vmhost_data->get_image_name();
		my $vmhost_os_module_package = $vmhost_data->get_image_os_module_perl_package();
		
		notify($ERRORS{'DEBUG'}, 0, "attempting to create OS object for the image currently loaded on the VM host: $vmhost_computer_name\nimage name: $vmhost_image_name\nOS module: $vmhost_os_module_package");
		
		if ($vmhost_os = $self->get_vmhost_os_object($vmhost_os_module_package)) {
			if ($vmhost_os->is_ssh_responding()) {
				notify($ERRORS{'DEBUG'}, 0, "OS of VM host $vmhost_computer_name will be controlled via SSH using OS object: " . ref($vmhost_os));
			}
			else {
				notify($ERRORS{'WARNING'}, 0, "unable to control OS of VM host $vmhost_computer_name using OS object: " . ref($vmhost_os) . ", VM host is not responding to SSH");
				return;
			}
		}
		else {
			notify($ERRORS{'WARNING'}, 0, "failed to create OS object to control the OS of VM host: $vmhost_computer_name");
			return;
		}
	}
	
	# Store the VM host and API objects in this object
	$self->{vmhost_os} = $vmhost_os;
	$self->{api} = $vmware_api;
	
	# Make sure the vmx and vmdk base directories can be accessed
	my $vmx_base_directory_path = $self->get_vmx_base_directory_path() || return;
	if (!$vmhost_os->file_exists($vmx_base_directory_path)) {
		notify($ERRORS{'WARNING'}, 0, "unable to access vmx base directory path: $vmx_base_directory_path");
		return;
	}
	my $vmdk_base_directory_path = $self->get_vmdk_base_directory_path() || return;
	if (($vmx_base_directory_path ne $vmdk_base_directory_path) && !$vmhost_os->file_exists($vmdk_base_directory_path)) {
		notify($ERRORS{'WARNING'}, 0, "unable to access vmdk base directory path: $vmdk_base_directory_path");
		return;
	}
	
	notify($ERRORS{'DEBUG'}, 0, "VMware provisioning object initialized:\nVM host OS object type: " . ref($self->{vmhost_os}) . "\nAPI object type: " . ref($self->{api}));
	
	return 1;
}

#/////////////////////////////////////////////////////////////////////////////

=head2 load

 Parameters  : none
 Returns     : boolean
 Description : Loads a VM with the requested image.

=cut

sub load {
	my $self = shift;
	if (ref($self) !~ /vmware/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}
	
	my $reservation_id = $self->data->get_reservation_id() || return;
	my $vmx_file_path = $self->get_vmx_file_path() || return;
	my $computer_id = $self->data->get_computer_id() || return;
	my $computer_name = $self->data->get_computer_short_name() || return;
	my $image_name = $self->data->get_image_name() || return;
	my $vmhost_hostname = $self->data->get_vmhost_hostname() || return;

	insertloadlog($reservation_id, $computer_id, "doesimageexists", "image exists $image_name");
	
	insertloadlog($reservation_id, $computer_id, "startload", "$computer_name $image_name");
	
	# Check if the .vmdk files exist, copy them if necessary
	if (!$self->prepare_vmdk()) {
		notify($ERRORS{'WARNING'}, 0, "failed to prepare vmdk file for $computer_name on VM host: $vmhost_hostname");
		return;
	}
	insertloadlog($reservation_id, $computer_id, "transfervm", "copied $image_name to $computer_name");
	
	# Generate the .vmx file
	if (!$self->prepare_vmx()) {
		notify($ERRORS{'WARNING'}, 0, "failed to prepare vmx file for $computer_name on VM host: $vmhost_hostname");
		return;
	}
	insertloadlog($reservation_id, $computer_id, "vmsetupconfig", "prepared vmx file");
	
	# Register the VM
	if (!$self->api->vm_register($vmx_file_path)) {
		notify($ERRORS{'WARNING'}, 0, "failed to register VM $computer_name on VM host: $vmhost_hostname");
		return;
	}
	
	# Power on the VM
	if (!$self->api->vm_power_on($vmx_file_path)) {
		notify($ERRORS{'WARNING'}, 0, "failed to power on VM $computer_name on VM host: $vmhost_hostname");
		return;
	}
	insertloadlog($reservation_id, $computer_id, "startvm", "registered and powered on $computer_name");
	
	# Call the OS module's post_load() subroutine if implemented
	if ($self->os->can("post_load") && !$self->os->post_load()) {
		notify($ERRORS{'WARNING'}, 0, "failed to perform OS post-load tasks on VM $computer_name on VM host: $vmhost_hostname");
		return;
	}
	insertloadlog($reservation_id, $computer_id, "loadimagecomplete", "performed OS post-load tasks on $computer_name");
	
	return 1;
}

#/////////////////////////////////////////////////////////////////////////////

=head2 capture

 Parameters  : none
 Returns     : boolean
 Description : Captures a VM image.

=cut

sub capture {
	my $self = shift;
	if (ref($self) !~ /VCL::Module/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}
	
	my $computer_name = $self->data->get_computer_short_name() || return;
	my $vmhost_hostname = $self->data->get_vmhost_hostname() || return;
	my $vmprofile_vmdisk = $self->data->get_vmhost_profile_vmdisk() || return;
	my $image_name = $self->data->get_image_name() || return;
	my $vmhost_profile_datastore_path = $self->data->get_vmhost_profile_datastore_path();
	
	# Get the MAC addresses being used by the running VM for this imaging reservation
	my @vm_mac_addresses = ($self->os->get_private_mac_address(), $self->os->get_public_mac_address());
	if (!@vm_mac_addresses) {
		notify($ERRORS{'WARNING'}, 0, "unable to retrieve the private or public MAC address being used by the VM, needed to determine which vmx to capture");
		return;
	}
	
	# Remove the colons from the MAC addresses and convert to lower case so they can be compared
	map { s/[^\w]//g; $_ = lc($_) } (@vm_mac_addresses);
	
	# Get the details of all the vmx files on the VM host
	my $host_vmx_info = $self->get_vmx_info() || return;
	
	# Check the vmx files on the VM host, find any with matching MAC addresses
	my @matching_host_vmx_paths;
	for my $host_vmx_path (sort keys %$host_vmx_info) {
		my $vmx_file_name = $host_vmx_info->{$host_vmx_path}{"vmx_file_name"} || '';
		
		# Ignore the vmx file if it is not registered
		if (!$self->is_vm_registered($host_vmx_path)) {
			notify($ERRORS{'OK'}, 0, "ignoring vmx file because the VM is not registered: $host_vmx_path");
			next;
		}
		
		# Ignore the vmx file if the VM is powered on
		my $power_state = $self->api->get_vm_power_state($host_vmx_path) || 'unknown';
		if ($power_state !~ /on/i) {
			notify($ERRORS{'DEBUG'}, 0, "ignoring vmx file because the VM is not powered on: $host_vmx_path");
			next;
		}
		
		notify($ERRORS{'DEBUG'}, 0, "checking if vmx file is the one being used by $computer_name: $host_vmx_path");
		
		# Create an array containing the values of any ethernetx.address or ethernetx.generatedaddress lines
		my @vmx_mac_addresses;
		for my $vmx_property (keys %{$host_vmx_info->{$host_vmx_path}}) {
			if ($vmx_property =~ /^ethernet\d+\.(generated)?address$/i) {
				push @vmx_mac_addresses, $host_vmx_info->{$host_vmx_path}{$vmx_property};
			}
		}
		
		# Remove the colons from the MAC addresses and convert to lowercase so they can be compared
		map { s/[^\w]//g; $_ = lc($_) } (@vmx_mac_addresses);
		
		# Check if any elements of the VM MAC address array intersect with the vmx MAC address array
		notify($ERRORS{'DEBUG'}, 0, "comparing MAC addresses\nused by $computer_name:\n" . join("\n", sort(@vm_mac_addresses)) . "\nconfigured in $host_vmx_path:\n" . join("\n", sort(@vmx_mac_addresses)));
		my @matching_mac_addresses = map { my $vm_mac_address = $_; grep(/$vm_mac_address/i, @vmx_mac_addresses) } @vm_mac_addresses;
		if (@matching_mac_addresses) {
			notify($ERRORS{'DEBUG'}, 0, "found matching MAC address between $computer_name and $vmx_file_name:\n" . join("\n", sort(@matching_mac_addresses)));
			push @matching_host_vmx_paths, $host_vmx_path;
		}
		else {
			notify($ERRORS{'DEBUG'}, 0, "did NOT find matching MAC address between $computer_name and $vmx_file_name");
		}
	}
	
	# Check if any matching vmx files were found
	if (!@matching_host_vmx_paths) {
		notify($ERRORS{'WARNING'}, 0, "did not find any vmx files on the VM host containing a MAC address matching $computer_name");
		return;
	}
	elsif (scalar(@matching_host_vmx_paths) > 1) {
		notify($ERRORS{'WARNING'}, 0, "found multiple vmx files on the VM host containing a MAC address matching $computer_name:\n" . join("\n", @matching_host_vmx_paths));
		return
	}
	
	my $vmx_file_path = $matching_host_vmx_paths[0];
	notify($ERRORS{'OK'}, 0, "found vmx file being used by $computer_name: $vmx_file_path");
	
	# Set the vmx file path in this object so that it overrides the default value that would normally be constructed
	$self->set_vmx_file_path($vmx_file_path) || return;
	
	# Get the information contained within the vmx file
	my $vmx_info = $host_vmx_info->{$vmx_file_path};
	notify($ERRORS{'DEBUG'}, 0, "vmx info for VM to be captured:\n" . format_data($vmx_info));
	
	# Get the vmdk info from the vmx info
	my @vmdk_identifiers = keys %{$vmx_info->{vmdk}};
	if (!@vmdk_identifiers) {
		notify($ERRORS{'WARNING'}, 0, "did not find vmdk file in vmx info ({vmdk} key):\n" . format_data($vmx_info));
		return;
	}
	elsif (scalar(@vmdk_identifiers) > 1) {
		notify($ERRORS{'WARNING'}, 0, "found multiple vmdk files in vmx info ({vmdk} keys):\n" . format_data($vmx_info));
		return;
	}
	
	# Get the vmdk file path from the vmx information
	my $vmdk_file_path = $vmx_info->{vmdk}{$vmdk_identifiers[0]}{vmdk_file_path};
	if (!$vmdk_file_path) {
		notify($ERRORS{'WARNING'}, 0, "vmdk file path was not found in the vmx info:\n" . format_data($vmx_info));
		return;	
	}
	notify($ERRORS{'DEBUG'}, 0, "vmdk file path used by the VM: $vmdk_file_path");
	
	# Get the vmdk mode from the vmx information and make sure it's persistent
	my $vmdk_mode = $vmx_info->{vmdk}{$vmdk_identifiers[0]}{mode};
	if (!$vmdk_mode) {
		notify($ERRORS{'WARNING'}, 0, "vmdk mode was not found in the vmx info:\n" . format_data($vmx_info));
		return;	
	}
	elsif ($vmdk_mode !~ /(independent-)?persistent/i) {
		notify($ERRORS{'WARNING'}, 0, "vmdk mode is not persistent: $vmdk_mode");
		return;	
	}
	notify($ERRORS{'DEBUG'}, 0, "vmdk mode is valid: $vmdk_mode");
	
	# Set the vmdk file path in this object so that it overrides the default value that would normally be constructed
	$self->set_vmdk_file_path($vmdk_file_path) || return;
	
	# Construct the vmdk file path where the captured image will be saved to
	my $vmdk_renamed_file_path = "$vmhost_profile_datastore_path/$image_name/$image_name.vmdk";
	
	# Make sure the vmdk file path for the captured image doesn't already exist
	if ($vmdk_file_path ne $vmdk_renamed_file_path && $self->vmhost_os->file_exists($vmdk_renamed_file_path)) {
		notify($ERRORS{'WARNING'}, 0, "vmdk file for captured image already exists: $vmdk_renamed_file_path");
		return;
	}
	
	# Write the details about the new image to ~/currentimage.txt
	write_currentimage_txt($self->data) || return;
	
	# Call the OS module's pre_capture() subroutine if implemented
	if ($self->os->can("pre_capture")) {
		$self->os->pre_capture({end_state => 'off'}) || return;
	}
	
	# Power off the VM if it's not already off
	my $vm_power_state = $self->api->get_vm_power_state($vmx_file_path) || return;
	if ($vm_power_state !~ /off/i) {
		$self->api->vm_power_off($vmx_file_path) || return;
		
		# Sleep for 5 seconds to make sure the power off is complete
		sleep 5;
	}
	
	## Get a lockfile so that only 1 process is operating on VM host files at any one time
	#my $lockfile = $self->get_lockfile("/tmp/$vmhost_hostname.lock", (60 * 10)) || return;
	
	# Rename the vmdk files on the VM host and change the vmdk directory name to the image name
	# This ensures that the vmdk and vmx files now reside in different directories
	#   so that the vmdk files can't be deleted when the vmx directory is deleted later on
	if ($vmdk_file_path ne $vmdk_renamed_file_path) {
		$self->rename_vmdk($vmdk_file_path, $vmdk_renamed_file_path) || return;
		$self->set_vmdk_file_path($vmdk_renamed_file_path) || return;
	}
	else {
		notify($ERRORS{'DEBUG'}, 0, "vmdk file does not need to be renamed: $vmdk_file_path");
	}
	
	# Check if the VM host is using local or network-based disk to store vmdk files
	# Don't have to do anything else for network disk because the vmdk directory has already been renamed
	if ($vmprofile_vmdisk eq "localdisk") {
		# Get the vmdk directory path
		my $vmdk_directory_path = $self->get_vmdk_directory_path() || return;
		
		# Copy the vmdk directory from the VM host to the image repository
		my @vmdk_copy_paths = $self->vmhost_os->find_files($vmdk_directory_path, '*.vmdk');
		if (!@vmdk_copy_paths) {
			notify($ERRORS{'WARNING'}, 0, "unable to find vmdk file paths on VM host to copy back to the managment node, vmdk directory path: $vmdk_directory_path, pattern: *.vmdk");
			return;
		}
		
		my $repository_directory_path = $self->get_repository_vmdk_directory_path() || return;
		
		# Loop through the files, copy each to the management node's repository directory
		for my $vmdk_copy_path (@vmdk_copy_paths) {
			my ($vmdk_copy_name) = $vmdk_copy_path =~ /([^\/]+)$/g;
			if (!$self->vmhost_os->copy_file_from($vmdk_copy_path, "$repository_directory_path/$vmdk_copy_name")) {
				notify($ERRORS{'WARNING'}, 0, "failed to copy vmdk file from the VM host to the management node:\n '$vmdk_copy_path' --> '$repository_directory_path/$vmdk_copy_name'");
				return;
			}
		}
		
		# Delete the vmdk directory on the VM host
		$self->vmhost_os->delete_file($vmdk_directory_path) || return;
	}
	
	# Unregister the VM
	$self->api->vm_unregister($vmx_file_path) || return;
	
	# Delete the vmx directory
	if ($self->get_vmx_directory_path() ne $self->get_vmdk_directory_path()) {
		$self->vmhost_os->delete_file($self->get_vmx_directory_path()) || return;
	}
	else {
		notify($ERRORS{'WARNING'}, 0, "vmx directory not deleted because it matches the vmdk directory, this should never happen: " . $self->get_vmdk_directory_path());
		return;
	}
	
	return 1;
}

#/////////////////////////////////////////////////////////////////////////////

=head2 node_status

 Parameters  : none
 Returns     : string -- 'READY' or 'RELOAD'
 Description : Checks the status of a VM. 'READY' is returned if the VM is
               registered, powered on, accessible via SSH, and the image loaded
               matches the requested image.  'RELOAD' is returned otherwise.

=cut

sub node_status {
	my $self = shift;
	if (ref($self) !~ /VCL::Module/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}
	
	my $computer_name = $self->data->get_computer_short_name();
	
	# Check if the VM is registered
	if ($self->is_vm_registered()) {
		notify($ERRORS{'DEBUG'}, 0, "VM $computer_name is registered");
	}
	else {
		notify($ERRORS{'DEBUG'}, 0, "VM $computer_name is not registered, returning 'RELOAD'");
		return {'status' => 'RELOAD'};
	}
	
	# Check if the VM is powered on
	my $power_status = $self->power_status();
	if ($power_status && $power_status =~/on/i) {
		notify($ERRORS{'DEBUG'}, 0, "VM $computer_name is powered on");
	}
	else {
		notify($ERRORS{'DEBUG'}, 0, "VM $computer_name is not powered on, returning 'RELOAD'");
		return {'status' => 'RELOAD'};
	}
	
	# Check if SSH is available
	if ($self->os->is_ssh_responding()) {
		notify($ERRORS{'DEBUG'}, 0, "VM $computer_name is responding to SSH");
	}
	else {
		notify($ERRORS{'DEBUG'}, 0, "VM $computer_name is not responding to SSH, returning 'RELOAD'");
		return {'status' => 'RELOAD'};
	}
	
	# Get the contents of currentimage.txt
	my $current_image_name = $self->os->get_current_image_name();
	if (!$current_image_name) {
		notify($ERRORS{'DEBUG'}, 0, "unable to retrieve image name from currentimage.txt on VM $computer_name, returning 'RELOAD'");
		return {'status' => 'RELOAD'};
	}
	
	# Check if currentimage.txt matches the requested image name
	my $image_name = $self->data->get_image_name();
	if ($current_image_name eq $image_name) {
		notify($ERRORS{'DEBUG'}, 0, "currentimage.txt image ($current_image_name) matches requested image name ($image_name) on VM $computer_name, returning 'READY'");
		return {'status' => 'READY'};
	}
	else {
		notify($ERRORS{'DEBUG'}, 0, "currentimage.txt image ($current_image_name) does not match requested image name ($image_name) on VM $computer_name, returning 'RELOAD'");
		return {'status' => 'RELOAD'};
	}
}

#/////////////////////////////////////////////////////////////////////////////

=head2 vmhost_os

 Parameters  : none
 Returns     : OS object reference
 Description : Returns the OS object that is used to control the VM host.

=cut

sub vmhost_os {
	my $self = shift;
	if (ref($self) !~ /vmware/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}
	return $self->{vmhost_os};
}

#/////////////////////////////////////////////////////////////////////////////

=head2 api

 Parameters  : none
 Returns     : API object reference
 Description : Returns the VMware API object that is used to control VMs on the
               VM host.

=cut

sub api {
	my $self = shift;
	if (ref($self) !~ /vmware/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}
	
	if (!$self->{api}) {
		notify($ERRORS{'WARNING'}, 0, "api object is not defined");
		return;
	}
	
	return $self->{api};
}

#/////////////////////////////////////////////////////////////////////////////

=head2 get_vmhost_datastructure

 Parameters  : none
 Returns     : DataStructure object reference
 Description : Returns a DataStructure object containing the data for the VM
               host. The computer and image data stored in the object describe
               the VM host computer, not the VM. All of the other data in the
               DataStore object matches the data for the regular reservation
               DataStructure object.

=cut

sub get_vmhost_datastructure {
	my $self = shift;
	if (ref($self) !~ /vmware/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}
	
	my $request_data = $self->data->get_request_data() || return;
	my $reservation_id = $self->data->get_reservation_id() || return;
	my $vmhost_computer_id = $self->data->get_vmhost_computer_id() || return;
	my $vmhost_profile_image_id = $self->data->get_vmhost_profile_image_id() || return;
	
	# Create a DataStructure object containing computer data for the VM host
	my $vmhost_data = new VCL::DataStructure({request_data => $request_data,
																		 reservation_id => $reservation_id,
																		 computer_id => $vmhost_computer_id,
																		 image_id => $vmhost_profile_image_id});
	if (!$vmhost_data) {
		notify($ERRORS{'WARNING'}, 0, "unable to create DataStructure object for VM host");
		return;
	}
	
	# Get the VM host nodename from the DataStructure object which was created for it
	# This acts as a test to make sure the DataStructure object is working
	my $vmhost_computer_node_name = $vmhost_data->get_computer_node_name();
	if (!$vmhost_computer_node_name) {
		notify($ERRORS{'WARNING'}, 0, "unable to determine VM host node name from DataStructure object created for VM host");
		return;
	}
	
	notify($ERRORS{'DEBUG'}, 0, "created DataStructure object for VM host: $vmhost_computer_node_name");
	$self->{vmhost_data} = $vmhost_data;
	return $vmhost_data;
}

#/////////////////////////////////////////////////////////////////////////////

=head2 get_vmhost_os_object

 Parameters  : $vmhost_os_perl_package (optional)
 Returns     : OS object reference
 Description : Creates an OS object to be used to control the VM host OS. An
               optional argument may be specified containing the Perl package to
               instantiate. If an argument is not specified, the Perl package of
               the image currently installed on the VM host computer is used.

=cut

sub get_vmhost_os_object {
	my $self = shift;
	if (ref($self) !~ /vmware/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}
	
	# Get the VM host OS object type argument
	my $vmhost_os_perl_package = shift;
	
	# Get a DataStructure object containing the VM host's data
	my $vmhost_data = $self->get_vmhost_datastructure() || return;
	
	# Check if the VM host OS object type was specified as an argument
	if (!$vmhost_os_perl_package) {
		# Get the VM host OS module Perl package name
		$vmhost_os_perl_package = $vmhost_data->get_image_os_module_perl_package();
		if (!$vmhost_os_perl_package) {
			notify($ERRORS{'WARNING'}, 0, "unable to create DataStructure or OS object for VM host, failed to retrieve VM host image OS module Perl package name");
			return;
		}
	}
	
	# Load the VM host OS module if it is different than the one already loaded for the reservation image OS
	notify($ERRORS{'DEBUG'}, 0, "attempting to load VM host OS module: $vmhost_os_perl_package");
	eval "use $vmhost_os_perl_package";
	if ($EVAL_ERROR) {
		notify($ERRORS{'WARNING'}, 0, "VM host OS module could NOT be loaded: $vmhost_os_perl_package, error: $EVAL_ERROR");
		return;
	}
	notify($ERRORS{'DEBUG'}, 0, "VM host OS module loaded: $vmhost_os_perl_package");
	
	# Create an OS object for the VM host
	my $vmhost_os;
	eval { $vmhost_os = ($vmhost_os_perl_package)->new({data_structure => $vmhost_data}) };
	if ($vmhost_os) {
		notify($ERRORS{'OK'}, 0, "VM host OS object created: " . ref($vmhost_os));
		$self->{vmhost_os} = $vmhost_os;
		return $self->{vmhost_os};
	}
	elsif ($EVAL_ERROR) {
		notify($ERRORS{'WARNING'}, 0, "VM host OS object could not be created: type: $vmhost_os_perl_package, error:\n$EVAL_ERROR");
		return;
	}
	else {
		notify($ERRORS{'WARNING'}, 0, "VM host OS object could not be created, type: $vmhost_os_perl_package, no eval error");
		return;
	}
}

#/////////////////////////////////////////////////////////////////////////////

=head2 get_vsphere_sdk_object

 Parameters  : none
 Returns     : vSphere SDK object
 Description : Creates and returns a vSphere SDK object which can be used to
               control VMs on a VM host.

=cut

sub get_vsphere_sdk_object {
	my $self = shift;
	if (ref($self) !~ /vmware/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}
	
	# Get a DataStructure object containing the VM host's data
	my $vmhost_datastructure = $self->get_vmhost_datastructure() || return;
	
	# Get the VM host nodename from the DataStructure object which was created for it
	# This acts as a test to make sure the DataStructure object is working
	my $vmhost_nodename = $vmhost_datastructure->get_computer_node_name();
	if (!$vmhost_nodename) {
		notify($ERRORS{'WARNING'}, 0, "unable to determine VM host node name from DataStructure object created for VM host");
		return;
	}
	
	# Create a vSphere SDK object
	my $vsphere_sdk;
	eval { $vsphere_sdk = VCL::Module::Provisioning::VMware::vSphere_SDK->new({data_structure => $vmhost_datastructure}) };
	if (!$vsphere_sdk) {
		my $error = $EVAL_ERROR || 'no eval error';
		notify($ERRORS{'WARNING'}, 0, "vSphere SDK object could not be created, VM host: $vmhost_nodename, $error");
		return;
	}
	
	notify($ERRORS{'DEBUG'}, 0, "created vSphere SDK object, VM host: $vmhost_nodename");
	return $vsphere_sdk;
}

#/////////////////////////////////////////////////////////////////////////////

=head2 get_vix_api_object

 Parameters  : none
 Returns     : VIX API object reference
 Description : Creates and returns a VMware VIX API object which may be used to
               control the VMs on a VM host.

=cut

sub get_vix_api_object {
	my $self = shift;
	if (ref($self) !~ /vmware/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}
	
	# Get a DataStructure object containing the VM host's data
	my $vmhost_datastructure = $self->get_vmhost_datastructure() || return;
	
	# Get the VM host nodename from the DataStructure object which was created for it
	# This acts as a test to make sure the DataStructure object is working
	my $vmhost_nodename = $vmhost_datastructure->get_computer_node_name();
	if (!$vmhost_nodename) {
		notify($ERRORS{'WARNING'}, 0, "unable to determine VM host node name from DataStructure object created for VM host");
		return;
	}
	
	# Create a VIX API object
	my $vix_api;
	eval { $vix_api = VCL::Module::Provisioning::VMware::VIX_API->new({data_structure => $vmhost_datastructure}) };
	if (!$vix_api) {
		my $error = $EVAL_ERROR || 'no eval error';
		notify($ERRORS{'WARNING'}, 0, "VIX API object could not be created, VM host: $vmhost_nodename, $error");
		return;
	}
	
	notify($ERRORS{'OK'}, 0, "created VIX API object, VM host: $vmhost_nodename");
	return $vix_api;
}

#/////////////////////////////////////////////////////////////////////////////

=head2 prepare_vmx

 Parameters  : none
 Returns     : boolean
 Description : Creates a .vmx file on the VM host configured for the
               reservation. Checks if a VM for the same VCL computer entry is
               already registered. If the VM is already registered, it is
               unregistered and the files for the existing VM are deleted.

=cut

sub prepare_vmx {
	my $self = shift;
	if (ref($self) !~ /vmware/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}
	
	# Get the required data to configure the .vmx file
	my $image_id                 = $self->data->get_image_id() || return;
	my $imagerevision_id         = $self->data->get_imagerevision_id() || return;
	my $computer_id              = $self->data->get_computer_id() || return;
	my $vmx_file_name            = $self->get_vmx_file_name() || return;
	my $vmx_file_path            = $self->get_vmx_file_path() || return;
	my $vmx_directory_name       = $self->get_vmx_directory_name() || return;
	my $vmx_directory_path       = $self->get_vmx_directory_path() || return;
	my $vmdk_file_path           = $self->get_vmdk_file_path() || return;
	my $computer_name            = $self->data->get_computer_short_name() || return;
	my $image_name               = $self->data->get_image_name() || return;
	my $vm_ram                   = $self->get_vm_ram() || return;
	my $vm_cpu_count             = $self->data->get_image_minprocnumber() || 1;
	my $vm_ethernet_adapter_type = $self->get_vm_ethernet_adapter_type() || return;
	my $vm_eth0_mac              = $self->data->get_computer_eth0_mac_address() || return;
	my $vm_eth1_mac              = $self->data->get_computer_eth1_mac_address() || return;
	my $vm_private_ip_address    = $self->data->get_computer_ip_address() || return;
	my $vm_public_ip_address     = $self->data->get_computer_private_ip_address()  || return;
	my $virtual_switch_0         = $self->data->get_vmhost_profile_virtualswitch0() || return;
	my $virtual_switch_1         = $self->data->get_vmhost_profile_virtualswitch1() || return;
	my $vm_disk_adapter_type     = $self->get_vm_disk_adapter_type() || return;
	my $vm_hardware_version      = $self->get_vm_virtual_hardware_version() || return;
	my $vm_persistent            = $self->is_vm_persistent();
	my $guest_os                 = $self->get_vm_guest_os() || return;

	## Figure out how much additional space is required for the vmx directory for the VM for this reservation
	## This is the number of additional bytes which have not already been allocated the VM will likely use
	#my $vm_additional_vmx_bytes_required = $self->get_vm_additional_vmx_bytes_required();
	#return if !defined($vm_additional_vmx_bytes_required);
	#
	## Get the number of bytes available on the device where the base vmx directory resides
	#my $host_vmx_bytes_available = $self->vmhost_os->get_available_space($self->get_vmx_base_directory_path());
	#return if !defined($host_vmx_bytes_available);
	#
	## Check if there is enough space available for the VM's vmx files
	#if ($vm_additional_vmx_bytes_required > $host_vmx_bytes_available) {
	#	my $vmx_deficit_bytes = ($vm_additional_vmx_bytes_required - $host_vmx_bytes_available);
	#	my $vmx_deficit_mb = format_number($vmx_deficit_bytes / 1024 / 1024);
	#	notify($ERRORS{'WARNING'}, 0, "not enough space is available for the vmx files on the VM host, deficit: $vmx_deficit_bytes bytes ($vmx_deficit_mb MB)");
	#}
	#else {
	#	notify($ERRORS{'DEBUG'}, 0, "enough space is available for the vmx files on the VM host");
	#}
	
	# Get a hash containing info about all the .vmx files that exist on the VM host
	# Check the VMs on the host to see if any match the computer assigned to this reservation
	my $host_vmx_info = $self->get_vmx_info();
	for my $host_vmx_path (keys %$host_vmx_info) {
		my $host_vmx_computer_id = $host_vmx_info->{$host_vmx_path}{computer_id} || 'unknown';
		
		# If existing VM is for this computer, delete it
		if ($computer_id eq $host_vmx_computer_id) {
			notify($ERRORS{'DEBUG'}, 0, "found vmx file on VM host with matching computer id: $computer_id, $host_vmx_path");
			if (!$self->delete_vm($host_vmx_path)) {
				notify($ERRORS{'WARNING'}, 0, "failed to delete VM: $host_vmx_path");
				return;
			}
		}
	}
	
	# Get a list of the registered VMs
	# Make sure the .vmx file actually exists for the registered VM
	# A VM will remain in the registered list if the .vmx is deleted while it is registered
	# Unregister any VMs which are missing .vmx files
	my @registered_vmx_paths = $self->api->get_registered_vms();
	for my $registered_vmx_path (@registered_vmx_paths) {
		if (!$self->vmhost_os->file_exists($registered_vmx_path)) {
			notify($ERRORS{'WARNING'}, 0, "vmx is registered but vmx file does not exist: $registered_vmx_path");
			if (!$self->api->vm_unregister($registered_vmx_path)) {
				if ($registered_vmx_path eq $vmx_file_path) {
					notify($ERRORS{'WARNING'}, 0, "failed to unregister orphaned VM using the same vmx path as the VM for this reservation: $registered_vmx_path");
					return;
				}
				else {
					notify($ERRORS{'WARNING'}, 0, "failed to unregister orphaned VM using different vmx path than this reservation: $registered_vmx_path");
				}
			}
		}
	}
	
	# Create the .vmx directory on the host
	if (!$self->vmhost_os->create_directory($vmx_directory_path)) {
		notify($ERRORS{'WARNING'}, 0, "failed to create .vmx directory on VM host: $vmx_directory_path");
		return;
	}
	
	# Set the disk parameters based on whether or not persistent mode is used
	# Also set the display name to distinguish persistent and non-persistent VMs
	my $display_name;
	my $vm_disk_mode;
	my $vm_disk_write_through;
	if ($vm_persistent) {
		$display_name = "$computer_name (persistent: $image_name)";
		$vm_disk_mode = 'independent-persistent';
		$vm_disk_write_through = "TRUE";
	}
	else {
		$display_name = "$computer_name (nonpersistent: $image_name)";
		$vm_disk_mode = "independent-nonpersistent";
		#$vm_disk_mode = "undoable";
		$vm_disk_write_through = "FALSE";
	}
	
	notify($ERRORS{'DEBUG'}, 0, "vm info:
			 image ID: $image_id
			 imagerevision ID: $imagerevision_id
			 
			 vmx path: $vmx_file_path
			 vmx directory name: $vmx_directory_name
			 vmx directory path: $vmx_directory_path
			 vmdk file path: $vmdk_file_path
			 persistent: $vm_persistent
			 computer ID: $computer_id
			 computer name: $computer_name
			 image name: $image_name
			 guest OS: $guest_os
			 virtual hardware version: $vm_hardware_version
			 RAM: $vm_ram
			 CPU count: $vm_cpu_count
			 
			 ethernet adapter type: $vm_ethernet_adapter_type
			 
			 virtual switch 0: $virtual_switch_0
			 eth0 MAC address: $vm_eth0_mac
			 private IP address: $vm_private_ip_address
			 
			 virtual switch 1: $virtual_switch_1
			 eth1 MAC address: $vm_eth1_mac
			 public IP address: $vm_public_ip_address
			 
			 disk adapter type: $vm_disk_adapter_type
			 disk mode: $vm_disk_mode
			 disk write through: $vm_disk_write_through"
	);
	
	# Create a hash containing the vmx parameter names and values
	my %vmx_parameters = (
		"#image_id" => "$image_id",
		"#imagerevision_id" => "$imagerevision_id",
		"#computer_id" => "$computer_id",
		
		".encoding" => "UTF-8",
		
		"config.version" => "8",
		
		"displayName" => "$display_name",
		
		"ethernet0.address" => "$vm_eth0_mac",
		"ethernet0.addressType" => "static",
		"ethernet0.allowGuestConnectionControl" => "FALSE",
		"ethernet0.connectionType" => "custom",
		"ethernet0.present" => "TRUE",
		"ethernet0.virtualDev" => "$vm_ethernet_adapter_type",
		"ethernet0.vnet" => "$virtual_switch_0",
		"ethernet0.wakeOnPcktRcv" => "FALSE",
		
		"ethernet1.address" => "$vm_eth1_mac",
		"ethernet1.addressType" => "static",
		"ethernet1.allowGuestConnectionControl" => "FALSE",
		"ethernet1.connectionType" => "custom",
		"ethernet1.present" => "TRUE",
		"ethernet1.virtualDev" => "$vm_ethernet_adapter_type",
		"ethernet1.vnet" => "$virtual_switch_1",
		"ethernet1.wakeOnPcktRcv" => "FALSE",
		
		"floppy0.present" => "FALSE",
		
		"guestOS" => "$guest_os",
		
		"gui.exitOnCLIHLT" => "TRUE",	# causes the virtual machine to power off automatically when you choose Start > Shut Down from the Windows guest
		
		"memsize" => "$vm_ram",
		
		"msg.autoAnswer" => "TRUE",	# tries to automatically answer all questions that may occur at boot-time.
		
		"numvcpus" => "$vm_cpu_count",
		
		"powerType.powerOff" => "soft",
		"powerType.powerOn" => "hard",
		"powerType.reset" => "soft",
		"powerType.suspend" => "hard",
		
		"snapshot.disabled" => "TRUE",
		
		"tools.remindInstall" => "TRUE",
		"tools.syncTime" => "FALSE",
		
		"toolScripts.afterPowerOn" => "TRUE",
		"toolScripts.afterResume" => "TRUE",
		"toolScripts.beforeSuspend" => "TRUE",
		"toolScripts.beforePowerOff" => "TRUE",
		
		"uuid.action" => "keep",	# Keep the VM's uuid, keeps existing MAC								
		
		"virtualHW.version" => "$vm_hardware_version",
	);
	
	# Add the disk adapter parameters to the hash
	if ($vm_disk_adapter_type =~ /ide/i) {
		%vmx_parameters = (%vmx_parameters, (
			"ide0:0.fileName" => "$vmdk_file_path",
			"ide0:0.mode" => "$vm_disk_mode",
			"ide0:0.present" => "TRUE",
			"ide0:0.writeThrough" => "$vm_disk_write_through",
		));
	}
	else {
		%vmx_parameters = (%vmx_parameters, (
			"scsi0.present" => "TRUE",
			"scsi0.virtualDev" => "$vm_disk_adapter_type",
			"scsi0:0.fileName" => "$vmdk_file_path",
			"scsi0:0.mode" => "$vm_disk_mode",
			"scsi0:0.present" => "TRUE",
			"scsi0:0.writeThrough" => "$vm_disk_write_through",
		));
	}
	
	# Create a string from the hash
	my $vmx_contents = "#!/usr/bin/vmware\n";
	map { $vmx_contents .= "$_ = \"$vmx_parameters{$_}\"\n" } sort keys %vmx_parameters;
	
	# Create a temporary vmx file on this managment node in /tmp
	my $temp_vmx_file_path = "/tmp/$vmx_file_name";
	if (open VMX_TEMP, ">", $temp_vmx_file_path) {
		print VMX_TEMP $vmx_contents;
		close VMX_TEMP;
		notify($ERRORS{'DEBUG'}, 0, "created temporary vmx file: $temp_vmx_file_path");
	}
	else {
		notify($ERRORS{'WARNING'}, 0, "failed to create temporary vmx file: $temp_vmx_file_path, error: @!");
		return;
	}
	
	# Copy the temporary vmx file the the VM host
	$self->vmhost_os->copy_file_to($temp_vmx_file_path, $vmx_file_path) || return;
	notify($ERRORS{'OK'}, 0, "created vmx file on VM host: $vmx_file_path");
	
	# Delete the temporary vmx file
	if	(unlink $temp_vmx_file_path) {
		notify($ERRORS{'DEBUG'}, 0, "deleted temporary vmx file: $temp_vmx_file_path");
	}
	else {
		notify($ERRORS{'WARNING'}, 0, "failed to delete temporary vmx file: $temp_vmx_file_path, error: $!");
	}
	
	return 1;
}

#/////////////////////////////////////////////////////////////////////////////

=head2 prepare_vmdk

 Parameters  : none
 Returns     : boolean
 Description : Prepares the .vmdk files on the VM host. This subroutine
               determines whether or not the vmdk files need to be copied to the
               VM host.

=cut

sub prepare_vmdk {
	my $self = shift;
	if (ref($self) !~ /vmware/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}
	
	my $host_vmdk_directory_path = $self->get_vmdk_directory_path() || return;
	my $repository_vmdk_directory_path = $self->get_repository_vmdk_directory_path() || return;
	my $image_name = $self->data->get_image_name() || return;
	my $vmhost_hostname = $self->data->get_vmhost_hostname() || return;
	
	# Check if the first .vmdk file exists on the host
	my $host_vmdk_file_path = $self->get_vmdk_file_path() || return;
	if ($self->vmhost_os->file_exists($host_vmdk_file_path)) {
		notify($ERRORS{'DEBUG'}, 0, ".vmdk file exists on VM host: $host_vmdk_file_path");
		return $self->check_vmdk_disk_type();
	}
	else {
		notify($ERRORS{'DEBUG'}, 0, ".vmdk file does NOT exist on VM host: $host_vmdk_file_path");
	}
	
	## Figure out how much additional space is required for the vmdk directory for the VM for this reservation
	## This is the number of additional bytes which have not already been allocated the VM will likely use
	## The subroutine checks if the vmdk files already exist on the VM host
	#my $vm_additional_vmdk_bytes_required = $self->get_vm_additional_vmdk_bytes_required();
	#return if !defined($vm_additional_vmdk_bytes_required);
	#
	## Get the number of bytes available on the device where the base vmdk directory resides
	#my $host_vmdk_bytes_available = $self->vmhost_os->get_available_space($self->get_vmdk_base_directory_path());
	#return if !defined($host_vmdk_bytes_available);
	#
	## Check if there is enough space available for the VM's vmdk files
	#if ($vm_additional_vmdk_bytes_required > $host_vmdk_bytes_available) {
	#	my $vmdk_deficit_bytes = ($vm_additional_vmdk_bytes_required - $host_vmdk_bytes_available);
	#	my $vmdk_deficit_mb = format_number($vmdk_deficit_bytes / 1024 / 1024);
	#	notify($ERRORS{'WARNING'}, 0, "not enough space is available for the vmdk files on the VM host, deficit: $vmdk_deficit_bytes bytes ($vmdk_deficit_mb MB)");
	#	return;
	#}
	#else {
	#	notify($ERRORS{'DEBUG'}, 0, "enough space is available for the vmdk files on the VM host");
	#}
	
	# Check if the VM is persistent, if so, attempt to copy files locally from the nonpersistent directory if they exist
	if ($self->is_vm_persistent()) {
		my $host_vmdk_directory_path_nonpersistent = $self->get_vmdk_directory_path_nonpersistent() || return;
		
		if (my @vmdk_nonpersistent_file_paths = $self->vmhost_os->find_files($host_vmdk_directory_path_nonpersistent, '*.vmdk')) {
			my $start_time = time;
			
			# Loop through the files, copy each file from the non-persistent directory to the persistent directory
			for my $vmdk_nonpersistent_file_path (sort @vmdk_nonpersistent_file_paths) {
				# Extract the file name from the path
				my ($vmdk_copy_file_name) = $vmdk_nonpersistent_file_path =~ /([^\/]+)$/g;
				
				# Attempt to copy the file on the VM host
				if (!$self->vmhost_os->copy_file($vmdk_nonpersistent_file_path, "$host_vmdk_directory_path/$vmdk_copy_file_name")) {
					notify($ERRORS{'WARNING'}, 0, "failed to copy vmdk file from the non-persistent to the persistent directory on the VM host:\n'$vmdk_nonpersistent_file_path' --> '$host_vmdk_directory_path/$vmdk_copy_file_name'");
					return;
				}
			}
			
			# All vmdk files were copied
			my $duration = (time - $start_time);
			notify($ERRORS{'OK'}, 0, "copied vmdk files from nonpersistent to persistent directory on VM host, took " . format_number($duration) . " seconds");
			return $self->check_vmdk_disk_type();
		}
		else {
			notify($ERRORS{'DEBUG'}, 0, "non-persistent set of vmdk files does not exist: '$host_vmdk_directory_path_nonpersistent'");
		}
	}
	
	# VM is either non-persistent or persistent and could not copy files from existing non-persistent directory
	# Copy the vmdk files from the image repository to the vmdk directory
	my $start_time = time;
	
	# Find the vmdk file paths in the image repository directory
	my @vmdk_repository_file_paths;
	my $command = "find \"$repository_vmdk_directory_path\" -type f -iname \"*.vmdk\"";
	my ($exit_status, $output) = run_command($command, 1);
	if (!defined($output)) {
		notify($ERRORS{'WARNING'}, 0, "failed to run command to find files in image repository directory: '$repository_vmdk_directory_path', pattern: '*.vmdk', command:\n$command");
		return;
	}
	elsif (grep(/(^find:.*no such file)/i, @$output)) {
		notify($ERRORS{'WARNING'}, 0, "directory does not exist in image repository: '$repository_vmdk_directory_path'");
		return;
	}
	elsif (grep(/(^find: |syntax error|unexpected EOF)/i, @$output)) {
		notify($ERRORS{'WARNING'}, 0, "error occurred attempting to find files in image repository directory: '$repository_vmdk_directory_path', pattern: '*.vmdk', command: $command, output:\n" . join("\n", @$output));
		return;
	}
	else {
		@vmdk_repository_file_paths = @$output;
		map { chomp $_ } @vmdk_repository_file_paths;
		notify($ERRORS{'DEBUG'}, 0, "found " . scalar(@vmdk_repository_file_paths) . " vmdk files in image repository directory: '$repository_vmdk_directory_path':\n" . join("\n", sort @vmdk_repository_file_paths));
	}
	
	# Loop through the files, copy each from the management node's repository directory to the VM host
	for my $vmdk_repository_file_path (sort @vmdk_repository_file_paths) {
		my ($vmdk_copy_name) = $vmdk_repository_file_path =~ /([^\/]+)$/g;
		if (!$self->vmhost_os->copy_file_to($vmdk_repository_file_path, "$host_vmdk_directory_path/$vmdk_copy_name")) {
			notify($ERRORS{'WARNING'}, 0, "failed to copy vmdk file from the repository to the VM host: '$vmdk_repository_file_path' --> '$host_vmdk_directory_path/$vmdk_copy_name'");
			return;
		}
	}
	my $duration = (time - $start_time);
	notify($ERRORS{'OK'}, 0, "copied .vmdk files from management node image repository to the VM host, took " . format_number($duration) . " seconds");
	
	return $self->check_vmdk_disk_type();
}

#/////////////////////////////////////////////////////////////////////////////

=head2 check_vmdk_disk_type

 Parameters  : none
 Returns     : boolean
 Description : Determines if the vmdk disk type is compatible with the VMware
               product being used on the VM host. This subroutine currently only
               checks if ESX is being used and the vmdk disk type is flat. If
               using ESX and the disk type is not flat, a copy of the vmdk is
               created using the thin virtual disk type in the same directory as
               the incompatible vmdk directory. The name of the copied vmdk file
               is the same as the incompatible vmdk file with '-thin' inserted
               before '.vmdk'. Example:
               'vmwarewinxp-base1-v0.vmdk' --> 'vmwarewinxp-base1-v0-thin.vmdk'
               
               This subroutine returns true unless ESX is being used, the
               virtual disk type is not flat, and a thin copy cannot be created.

=cut

sub check_vmdk_disk_type {
	my $self = shift;
	if (ref($self) !~ /vmware/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}
	
	my $vmdk_file_path = $self->get_vmdk_file_path() || return;
	
	# Check if the API object implements the required subroutines
	unless ($self->api->can("get_vmware_product_name")
			  && $self->api->can("get_virtual_disk_type")
			  && $self->api->can("copy_virtual_disk")
			  && $self->api->can("get_virtual_disk_controller_type")) {
		notify($ERRORS{'DEBUG'}, 0, "skipping vmdk disk type check because required subroutines are not implemented by the API object");
		return 1;
	}
	
	# Retrieve the VMware product name and virtual disk type from the API object
	my $vmware_product_name = $self->api->get_vmware_product_name();
	if (!$vmware_product_name) {
		notify($ERRORS{'DEBUG'}, 0, "skipping vmdk disk type check because VMware product name could not be retrieved from the API object");
		return 1;
	}
	my $virtual_disk_type = $self->api->get_virtual_disk_type($vmdk_file_path);
	if (!$vmware_product_name) {
		notify($ERRORS{'DEBUG'}, 0, "skipping vmdk disk type check because virtual disk type could not be retrieved from the API object");
		return 1;
	}
	
	if ($vmware_product_name =~ /esx/i) {
		if ($virtual_disk_type !~ /flat/i) {
			notify($ERRORS{'DEBUG'}, 0, "virtual disk type is NOT compatible with $vmware_product_name: $virtual_disk_type");
			
			my $vmdk_file_path = $self->get_vmdk_file_path() || return;
			my $vmdk_directory_path = $self->get_vmdk_directory_path() || return;
			my $vmdk_file_prefix = $self->get_vmdk_file_prefix() || return;
			my $thin_vmdk_file_path = "$vmdk_directory_path/$vmdk_file_prefix-thin.vmdk";
			
			if ($self->vmhost_os->file_exists($thin_vmdk_file_path)) {
				notify($ERRORS{'DEBUG'}, 0, "thin virtual disk already exists: $thin_vmdk_file_path");
			}
			else {
				notify($ERRORS{'DEBUG'}, 0, "attempting to create a copy of the virtual disk using the thin virtual disk type: $thin_vmdk_file_path");
				
				# Get the controller type from the incompatible vmdk file, use it to create the copy
				my $virtual_disk_controller_type = $self->api->get_virtual_disk_controller_type($vmdk_file_path);
				if (!$virtual_disk_controller_type) {
					notify($ERRORS{'WARNING'}, 0, "unable to create a copy of the virtual disk using the thin virtual disk type because the controller type used by the original vmdk file cannot be retrieved");
					return;
				}
				
				# Attempt to create a thin copy of the virtual disk
				if ($self->api->copy_virtual_disk($vmdk_file_path, $thin_vmdk_file_path, $virtual_disk_controller_type, 'thin')) {
					notify($ERRORS{'DEBUG'}, 0, "created a copy of the virtual disk using the thin virtual disk type: $thin_vmdk_file_path");
				}
				else {
					notify($ERRORS{'WARNING'}, 0, "failed to create a copy of the virtual disk using the thin virtual disk type: $thin_vmdk_file_path");
					return;
				}
			}
			
			# Update this object to use the thin vmdk file path
			if ($self->set_vmdk_file_path($thin_vmdk_file_path)) {
				return 1;
			}
			else {
				notify($ERRORS{'WARNING'}, 0, "failed to update the VMware module object to use the thin virtual disk path");
				return;
			}
		}
		else {
			notify($ERRORS{'DEBUG'}, 0, "virtual disk does not need to be converted for $vmware_product_name: $virtual_disk_type");
			return 1;
		}
	}
	else {
		notify($ERRORS{'DEBUG'}, 0, "skipping vmdk disk type check because VMware product is not ESX: $vmware_product_name");
		return 1;
	}
	
	return 1;
}

#/////////////////////////////////////////////////////////////////////////////

=head2 get_vmx_base_directory_path

 Parameters  : none
 Returns     : string
 Description : Returns the path on the VM host under which the vmx directory is
               located.  Example:
               vmx file path: /vmfs/volumes/nfs-vmpath/vm1-6-987-v0/vm1-6-987-v0.vmx
               vmx base directory path: /vmfs/volumes/nfs-vmpath

=cut

sub get_vmx_base_directory_path {
	my $self = shift;
	if (ref($self) !~ /vmware/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}
	
	my $vmx_base_directory_path;
	
	my $vmhost_profile_vmpath = $self->data->get_vmhost_profile_vmpath();
	if ($vmhost_profile_vmpath) {
		$vmhost_profile_vmpath =~ s/\\//g;
		$vmx_base_directory_path = $vmhost_profile_vmpath;
	}
	else {
		my $vmhost_profile_datastore_path = $self->data->get_vmhost_profile_datastore_path();
		if ($vmhost_profile_datastore_path) {
			$vmhost_profile_datastore_path =~ s/\\//g;
			$vmx_base_directory_path = $vmhost_profile_datastore_path;
		}
		else {
			notify($ERRORS{'WARNING'}, 0, "unable to determine the vmdk base directory, could not determine VM path or datastore path from the database");
			return;
		}
	}
	
	# Remove any trailing slashes
	$vmx_base_directory_path =~ s/\/$//g;
	return $vmx_base_directory_path;
}

#/////////////////////////////////////////////////////////////////////////////

=head2 get_vmx_directory_name

 Parameters  : none
 Returns     : string
 Description : Returns the name of the directory in which the .vmx file is
               located.  The name differs depending on whether or not the VM
               is persistent.
               If not persistent: <computer name>_<image ID>-<revision>
               If persistent: <computer name>_<image ID>-<revision>_<request ID>

=cut

sub get_vmx_directory_name {
	my $self = shift;
	if (ref($self) !~ /vmware/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}
	
	my $vmx_directory_name;

	if ($ENV{vmx_file_path}) {
		my $vmx_base_directory_path = $self->get_vmx_base_directory_path() || return;
		($vmx_directory_name) = $ENV{vmx_file_path} =~ /^$vmx_base_directory_path\/(.+)\/[^\/]+.vmx$/;
		return $vmx_directory_name;
	}
	
	# Get the computer name, image ID, and revision number
	my $computer_short_name = $self->data->get_computer_short_name();
	if (!$computer_short_name) {
		notify($ERRORS{'WARNING'}, 0, "unable to retrieve computer short name");
		return;
	}
	my $image_id = $self->data->get_image_id();
	if (!defined($image_id)) {
		notify($ERRORS{'WARNING'}, 0, "unable to retrieve image ID");
		return;
	}
	my $imagerevision_revision = $self->data->get_imagerevision_revision();
	if (!defined($imagerevision_revision)) {
		notify($ERRORS{'WARNING'}, 0, "unable to retrieve imagerevision revision");
		return;
	}
	
	# Assemble the directory name
	$vmx_directory_name = "$computer_short_name\_$image_id-v$imagerevision_revision";
	
	# If persistent, append the request ID
	if ($self->is_vm_persistent()) {
		my $request_id = $self->data->get_request_id();
		if (!defined($request_id)) {
			notify($ERRORS{'WARNING'}, 0, "unable to retrieve request ID");
			return;
		}
		$vmx_directory_name .= "\_$request_id";
	}
	
	return $vmx_directory_name;
}

#/////////////////////////////////////////////////////////////////////////////

=head2 get_vmx_directory_path

 Parameters  : none
 Returns     : string
 Description : Returns the path on the VM host under which the vmx file is
               located.  Example:
               vmx file path: /vmfs/volumes/nfs-vmpath/vm1-6-987-v0/vm1-6-987-v0.vmx
               vmx directory path: /vmfs/volumes/nfs-vmpath/vm1-6-987-v0

=cut

sub get_vmx_directory_path {
	my $self = shift;
	if (ref($self) !~ /vmware/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}
	
	my $vmx_base_directory_path = $self->get_vmx_base_directory_path() || return;
	my $vmx_directory_name = $self->get_vmx_directory_name() || return;
	
	return "$vmx_base_directory_path/$vmx_directory_name";
}

#/////////////////////////////////////////////////////////////////////////////

=head2 get_vmx_file_name

 Parameters  : none
 Returns     : string
 Description : Returns the name of the .vmx file.  Example:
               vmx file path: /vmfs/volumes/nfs-vmpath/vm1-6-987-v0/vm1-6-987-v0.vmx
               vmx file name: vm1-6-987-v0.vmx

=cut

sub get_vmx_file_name {
	my $self = shift;
	if (ref($self) !~ /vmware/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}
	
	if ($ENV{vmx_file_path}) {
		my ($vmx_file_name) = $ENV{vmx_file_path} =~ /([^\/]+.vmx)$/g;
	}
	
	my $vmx_directory_name = $self->get_vmx_directory_name() || return;
	return "$vmx_directory_name.vmx";
}

#/////////////////////////////////////////////////////////////////////////////

=head2 get_vmx_file_path

 Parameters  : none
 Returns     : string
 Description : Returns the path to the .vmx file.  Example:
               vmx file path: /vmfs/volumes/nfs-vmpath/vm1-6-987-v0/vm1-6-987-v0.vmx

=cut

sub get_vmx_file_path {
	my $self = shift;
	if (ref($self) !~ /vmware/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}
	
	return $ENV{vmx_file_path} if $ENV{vmx_file_path};
	
	my $vmx_directory_path = $self->get_vmx_directory_path() || return;
	my $vmx_file_name = $self->get_vmx_file_name() || return;
	return "$vmx_directory_path/$vmx_file_name";
}

#/////////////////////////////////////////////////////////////////////////////

=head2 get_vmdk_base_directory_path

 Parameters  : none
 Returns     : string
 Description : Returns the directory path under which the directories which
               store the .vmdk files are located.  Example:
               vmdk file path: /vmfs/volumes/nfs-datastore/vmwarewinxp-base234-v12/vmwarewinxp-base234-v12.vmdk
               vmdk base directory path: /vmfs/volumes/nfs-datastore

=cut

sub get_vmdk_base_directory_path {
	my $self = shift;
	if (ref($self) !~ /vmware/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}
	
	# Check if $ENV{vmdk_file_path} is set, parse this path if it is set
	if (my $vmdk_file_path = $ENV{vmdk_file_path}) {
		my ($vmdk_base_directory_path) = $vmdk_file_path =~ /^(.+)\/[^\/]+\/[^\/]+\.vmdk$/g;
		if (!$vmdk_base_directory_path) {
			notify($ERRORS{'WARNING'}, 0, "unable to determine vmdk base directory path from vmdk file path: $vmdk_file_path");
			return;
		}
		return $vmdk_base_directory_path;
	}
	else {
		# Get the VM host profile datastore path
		my $vmhost_profile_datastore_path = $self->data->get_vmhost_profile_datastore_path();
		if (!$vmhost_profile_datastore_path) {
			notify($ERRORS{'WARNING'}, 0, "unable to retrieve VM host profile datastore path");
			return;
		}
		return $vmhost_profile_datastore_path;
	}
}

#/////////////////////////////////////////////////////////////////////////////

=head2 get_vmdk_directory_name

 Parameters  : none
 Returns     : string
 Description : Returns the name of the directory under which the .vmdk files
               are located. The name differs depending on whether or not the
               VM is persistent.
               If not persistent: <image name>
               If persistent: <computer name>_<image ID>-<revision>_<request ID>
               Example:
               vmdk directory path persistent: vmwarewinxp-base234-v12
               vmdk directory path non-persistent: vm1-6_987-v0_5435

=cut

sub get_vmdk_directory_name {
	my $self = shift;
	if (ref($self) !~ /vmware/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}
	
	if ($self->is_vm_persistent()) {
		return $self->get_vmdk_directory_name_persistent();
	}
	else {
		return $self->get_vmdk_directory_name_nonpersistent();
	}
}

#/////////////////////////////////////////////////////////////////////////////

=head2 get_vmdk_directory_name_persistent

 Parameters  : none
 Returns     : string
 Description : Returns the name of the directory under which the .vmdk files
               are located if the VM is persistent:
               <computer name>_<image ID>-<revision>_<request ID>

=cut

sub get_vmdk_directory_name_persistent {
	my $self = shift;
	if (ref($self) !~ /vmware/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}
	
	if ($ENV{vmdk_file_path}) {
		my $vmdk_base_directory_path = $self->get_vmdk_base_directory_path() || return;
		my ($vmdk_directory_name) = $ENV{vmdk_file_path} =~ /^$vmdk_base_directory_path\/(.+)\/[^\/]+.vmdk$/;
		if ($vmdk_directory_name) {
			return $vmdk_directory_name;
		}
		else {
			notify($ERRORS{'WARNING'}, 0, "unable to parse vmdk directory name from vmdk file path: $ENV{vmdk_file_path}");
			return;
		}
	}
	
	return $self->get_vmx_directory_name();
}

#/////////////////////////////////////////////////////////////////////////////

=head2 get_vmdk_directory_name_nonpersistent

 Parameters  : none
 Returns     : string
 Description : Returns the name of the directory under which the .vmdk files
               are located if the VM is not persistent:
               <image name>

=cut

sub get_vmdk_directory_name_nonpersistent {
	my $self = shift;
	if (ref($self) !~ /vmware/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}
	
	if ($ENV{vmdk_file_path}) {
		my $vmdk_base_directory_path = $self->get_vmdk_base_directory_path() || return;
		my ($vmdk_directory_name) = $ENV{vmdk_file_path} =~ /^$vmdk_base_directory_path\/(.+)\/[^\/]+.vmdk$/;
		
		if ($vmdk_directory_name) {
			return $vmdk_directory_name;
		}
		else {
			notify($ERRORS{'WARNING'}, 0, "unable to parse vmdk directory name from vmdk file path: $ENV{vmdk_file_path}");
			return;
		}
	}
	
	my $image_name = $self->data->get_image_name();
	if (!$image_name) {
		notify($ERRORS{'WARNING'}, 0, "unable determine vmdk directory name because unable to retrieve image name");
		return;
	}
	return $image_name;
}

#/////////////////////////////////////////////////////////////////////////////

=head2 get_vmdk_directory_path

 Parameters  : none
 Returns     : string
 Description : Returns the directory path under which the .vmdk files are
               located.  Example:
               vmdk file path: /vmfs/volumes/nfs-datastore/vmwarewinxp-base234-v12/vmwarewinxp-base234-v12.vmdk
               vmdk directory path: /vmfs/volumes/nfs-datastore/vmwarewinxp-base234-v12

=cut

sub get_vmdk_directory_path {
	my $self = shift;
	if (ref($self) !~ /vmware/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}
	
	my $vmdk_base_directory_path = $self->get_vmdk_base_directory_path();
	if (!$vmdk_base_directory_path) {
		notify($ERRORS{'WARNING'}, 0, "unable to determine vmdk directory path because vmdk base directory path could not be determined");
		return;
	}
	
	my $vmdk_directory_name = $self->get_vmdk_directory_name() || return;
	if (!$vmdk_directory_name) {
		notify($ERRORS{'WARNING'}, 0, "unable to determine vmdk directory path because vmdk directory name could not be determined");
		return;
	}
	
	return "$vmdk_base_directory_path/$vmdk_directory_name";
}

#/////////////////////////////////////////////////////////////////////////////

=head2 get_vmdk_directory_path_nonpersistent

 Parameters  : none
 Returns     : string
 Description : Returns the directory path under which the .vmdk files are
               located for nonpersistent VMs.

=cut

sub get_vmdk_directory_path_nonpersistent {
	my $self = shift;
	if (ref($self) !~ /vmware/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}
	
	my $vmdk_base_directory_path = $self->get_vmdk_base_directory_path() || return;
	if (!$vmdk_base_directory_path) {
		notify($ERRORS{'WARNING'}, 0, "unable to determine nonpersistent vmdk directory path because vmdk base directory path could not be determined");
		return;
	}
	
	my $vmdk_directory_name = $self->get_vmdk_directory_name_nonpersistent() || return;
	if (!$vmdk_directory_name) {
		notify($ERRORS{'WARNING'}, 0, "unable to determine nonpersistent vmdk directory path because nonpersistent vmdk directory name could not be determined");
		return;
	}
	
	return "$vmdk_base_directory_path/$vmdk_directory_name";
}

#/////////////////////////////////////////////////////////////////////////////

=head2 get_vmdk_file_prefix

 Parameters  : none
 Returns     : string
 Description : Returns the name of the base .vmdk file without the trailing
               .vmdk. Example:
               vmdk file path: /vmfs/volumes/nfs-datastore/vmwarewinxp-base234-v12/vmwarewinxp-base234-v12.vmdk
               vmdk file prefix: vmwarewinxp-base234-v12

=cut

sub get_vmdk_file_prefix {
	my $self = shift;
	if (ref($self) !~ /vmware/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}
	
	if ($ENV{vmdk_file_path}) {
		my ($vmdk_file_prefix) = $ENV{vmdk_file_path} =~ /([^\/]+).vmdk$/g;
		return $vmdk_file_prefix;
	}
	
	my $image_name = $self->data->get_image_name() || return;
	return $image_name;
}

#/////////////////////////////////////////////////////////////////////////////

=head2 get_vmdk_file_name

 Parameters  : none
 Returns     : string
 Description : Returns the name of the base .vmdk file including .vmdk. Example:
               vmdk file path: /vmfs/volumes/nfs-datastore/vmwarewinxp-base234-v12/vmwarewinxp-base234-v12.vmdk
               vmdk file name: vmwarewinxp-base234-v12.vmdk

=cut

sub get_vmdk_file_name {
	my $self = shift;
	if (ref($self) !~ /vmware/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}
	
	my $vmdk_file_prefix = $self->get_vmdk_file_prefix() || return;
	if (!$vmdk_file_prefix) {
		notify($ERRORS{'WARNING'}, 0, "unable to determine vmdk file name because vmdk file prefix could not be determined");
		return;
	}
	
	return "$vmdk_file_prefix.vmdk";
}

#/////////////////////////////////////////////////////////////////////////////

=head2 get_vmdk_file_path_nonpersistent

 Parameters  : none
 Returns     : string
 Description : Returns the vmdk file path for a nonpersistent VM. This is
               useful when checking the image size on a VM host using
               network-based disks. It returns the vmdk file path that would be
               used for nonperistent VMs.

=cut

sub get_vmdk_file_path_nonpersistent {
	my $self = shift;
	if (ref($self) !~ /vmware/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}
	
	my $vmdk_directory_path_nonpersistent = $self->get_vmdk_directory_path_nonpersistent() || return;
	my $vmdk_file_name = $self->get_vmdk_file_name() || return;
	return "$vmdk_directory_path_nonpersistent/$vmdk_file_name";
}

#/////////////////////////////////////////////////////////////////////////////

=head2 get_vmdk_file_path

 Parameters  : none
 Returns     : string
 Description : Returns the path of the vmdk file. Example:
               vmdk file path: /vmfs/volumes/nfs-datastore/vmwarewinxp-base234-v12/vmwarewinxp-base234-v12.vmdk

=cut

sub get_vmdk_file_path {
	my $self = shift;
	if (ref($self) !~ /vmware/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}
	
	my $vmdk_directory_path = $self->get_vmdk_directory_path() || return;
	my $vmdk_file_name = $self->get_vmdk_file_name() || return;
	return "$vmdk_directory_path/$vmdk_file_name";
}

#/////////////////////////////////////////////////////////////////////////////

=head2 get_repository_vmdk_base_directory_path

 Parameters  : none
 Returns     : string
 Description : Returns the image repository directory path on the management
               node under which the vmdk directories for all of the images
               reside.  Example:
               repository vmdk file path: /install/vmware_images/vmwarewinxp-base234-v12/vmwarewinxp-base234-v12.vmdk
               repository vmdk base directory path: /install/vmware_images
					

=cut

sub get_repository_vmdk_base_directory_path {
	my $self = shift;
	if (ref($self) !~ /vmware/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}
	
	# Return the path stored in this object if it has already been determined
	return $self->{repository_base_directory} if (defined $self->{repository_base_directory});
	
	my $repository_vmdk_base_directory;
	# Return $VMWAREREPOSITORY if it's set (comes from VMWARE_IMAGEREPOSITORY value in vcld.conf)
	if ($VMWAREREPOSITORY) {
		$repository_vmdk_base_directory = $VMWAREREPOSITORY;
		notify($ERRORS{'DEBUG'}, 0, "using VMWARE_IMAGEREPOSITORY value from vcld.conf: $repository_vmdk_base_directory");
	}
	elsif (my $management_node_install_path = $self->data->get_management_node_install_path()) {
		$repository_vmdk_base_directory = "$management_node_install_path/vmware_images";
		notify($ERRORS{'DEBUG'}, 0, "using managementnode installpath database value: $repository_vmdk_base_directory");
	}
	else {
		$repository_vmdk_base_directory = "install/vmware_images";
		notify($ERRORS{'DEBUG'}, 0, "using hard-coded path: $repository_vmdk_base_directory");
	}
	
	# Set a value in this object so this doesn't have to be figured out more than once
	$self->{repository_base_directory} = $repository_vmdk_base_directory;
	return $repository_vmdk_base_directory;
}

#/////////////////////////////////////////////////////////////////////////////

=head2 get_repository_vmdk_directory_path

 Parameters  : none
 Returns     : string
 Description : Returns the image repository directory path on the management
               node under which the vmdk files reside.  Example:
               repository vmdk file path: /install/vmware_images/vmwarewinxp-base234-v12/vmwarewinxp-base234-v12.vmdk
               repository vmdk directory path: /install/vmware_images/vmwarewinxp-base234-v12

=cut

sub get_repository_vmdk_directory_path {
	my $self = shift;
	if (ref($self) !~ /vmware/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}
	
	my $repository_vmdk_base_directory = $self->get_repository_vmdk_base_directory_path() || return;
	my $image_name = $self->data->get_image_name() || return;
	return "$repository_vmdk_base_directory/$image_name";
}

#/////////////////////////////////////////////////////////////////////////////

=head2 get_repository_vmdk_file_path

 Parameters  : none
 Returns     : string
 Description : Returns the image repository vmdk file path on the management
               node.  Example:
               repository vmdk file path: /install/vmware_images/vmwarewinxp-base234-v12/vmwarewinxp-base234-v12.vmdk

=cut

sub get_repository_vmdk_file_path {
	my $self = shift;
	if (ref($self) !~ /vmware/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}
	
	my $repository_vmdk_directory_path = $self->get_repository_vmdk_directory_path() || return;
	my $vmdk_file_name = $self->get_vmdk_file_name() || return;
	return "$repository_vmdk_directory_path/$vmdk_file_name";
}

#/////////////////////////////////////////////////////////////////////////////

=head2 is_vm_persistent

 Parameters  : none
 Returns     : boolean
 Description : Determines if a VM should be persistent or not based on whether
               or not the reservation is an imaging reservation.

=cut

sub is_vm_persistent {
	my $self = shift;
	if (ref($self) !~ /vmware/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}
	
	my $request_forimaging = $self->data->get_request_forimaging();
	if ($request_forimaging) {
		return 1;
	}
	else {
		return 0;
	}
}

#/////////////////////////////////////////////////////////////////////////////

=head2 is_vm_registered

 Parameters  : $vmx_file_path (optional)
 Returns     : boolean
 Description : Determines if a VM is registered. An optional vmx file path
               argument can be supplied to check if a particular VM is
               registered. If an argument is not specified, the default vmx file
               path for the reservation is used.

=cut

sub is_vm_registered {
	my $self = shift;
	if (ref($self) !~ /vmware/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}
	
	# Get the vmx file path
	# Use the argument if one was supplied
	my $vmx_file_path = shift || $self->get_vmx_file_path() || return;
	
	my @registered_vmx_file_paths = $self->api->get_registered_vms();
	
	if (grep(/$vmx_file_path/, @registered_vmx_file_paths)) {
		notify($ERRORS{'DEBUG'}, 0, "vmx file is registered: $vmx_file_path");
		return 1;
	}
	else {
		notify($ERRORS{'DEBUG'}, 0, "vmx file is not registered: $vmx_file_path");
		return 0;
	}
}

#/////////////////////////////////////////////////////////////////////////////

=head2 get_image_size

 Parameters  : $vmdk_file_path (optional)
 Returns     : integer
 Description : Returns the size of the image in bytes. If the vmdk file path
               argument is not supplied and the VM disk type in the VM profile
               is set to localdisk, the size of the image in the image
               repository on the management node is checked. Otherwise, the size
               of the image in the vmdk directory on the VM host is checked.

=cut

sub get_image_size {
	my $self = shift;
	if (ref($self) !~ /vmware/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}
	
	my $vmhost_hostname = $self->data->get_vmhost_hostname() || return;
	my $vmprofile_vmdisk = $self->data->get_vmhost_profile_vmdisk() || return;

	# Attempt to get the vmdk file path argument
	# If not supplied, use the default vmdk file path for this reservation
	my $vmdk_file_path = shift;
	
	# Try to retrieve the image size from the repository if an argument was not supplied and localdisk is being used
	if (!$vmdk_file_path && $vmprofile_vmdisk eq "localdisk") {
		my $repository_vmdk_directory_path = $self->get_repository_vmdk_directory_path() || return;
		notify($ERRORS{'DEBUG'}, 0, "vm disk type is $vmprofile_vmdisk, checking size of vmdk directory in image repository: $repository_vmdk_directory_path");
		
		# Run du specifying image repository directory as an argument
		my ($exit_status, $output) = run_command("du -bc \"$repository_vmdk_directory_path\"", 1);
		if (!defined($output)) {
			notify($ERRORS{'WARNING'}, 0, "failed to run command to determine size of vmdk directory in image repository: $repository_vmdk_directory_path");
		}
		elsif (grep(/du: /i, @$output)) {
			notify($ERRORS{'WARNING'}, 0, "error occurred attempting to determine size of vmdk directory in image repository: $repository_vmdk_directory_path, output:\n" . join("\n", @$output));
		}
		else {
			my ($total_line) = grep(/total/, @$output);
			if (!$total_line) {
				notify($ERRORS{'WARNING'}, 0, "unable to locate 'total' line in du output while attempting to determine size of vmdk directory in image repository: $repository_vmdk_directory_path, output:\n" . join("\n", @$output));
			}
			else {
				my ($bytes_used) = $total_line =~ /(\d+)/;
				if ($bytes_used =~ /^\d+$/) {
					my $mb_used = format_number(($bytes_used / 1024 / 1024), 1);
					my $gb_used = format_number(($bytes_used / 1024 / 1024 / 1024), 2);
					notify($ERRORS{'DEBUG'}, 0, "size of vmdk directory in image repository $repository_vmdk_directory_path: " . format_number($bytes_used) . " bytes ($mb_used MB, $gb_used GB)");
					return $bytes_used;
				}
				else {
					notify($ERRORS{'WARNING'}, 0, "failed to parse du output to determine size of vmdk directory in image repository: $repository_vmdk_directory_path, output:\n" . join("\n", @$output));
					return;
				}
			}
		}
	}
	
	# Get the vmdk file path if not specified as an argument
	if (!$vmdk_file_path) {
		$vmdk_file_path = $self->get_vmdk_file_path() || return;
	}
	
	# Extract the directory path and file prefix from the vmdk file path
	my ($vmdk_directory_path, $vmdk_file_prefix) = $vmdk_file_path =~ /^(.+)\/([^\/]+)\.vmdk$/;
	if (!$vmdk_directory_path || !$vmdk_file_prefix) {
		notify($ERRORS{'WARNING'}, 0, "unable to determine vmdk directory path and vmdk file prefix from vmdk file path: $vmdk_file_path");
		return;
	}
	
	# Assemble a search path
	my $vmdk_search_path = "$vmdk_directory_path/$vmdk_file_prefix*.vmdk";
	
	# Get the size of the files on the VM host
	my $vmdk_size = $self->vmhost_os->get_file_size($vmdk_search_path);
	if (!defined($vmdk_size)) {
		notify($ERRORS{'WARNING'}, 0, "unable to determine the size of vmdk file on VM host $vmhost_hostname:
			 vmdk file path: $vmdk_file_path
			 search path: $vmdk_search_path");
		return;
	}
	
	notify($ERRORS{'DEBUG'}, 0, "size of vmdk file on VM host $vmhost_hostname $vmdk_file_path: " . format_number($vmdk_size) . " bytes");
	return $vmdk_size;
}

#/////////////////////////////////////////////////////////////////////////////

=head2 does_image_exist

 Parameters  : none
 Returns     : boolean
 Description : Determines if an image exists in either the management node's
               image repository or on the VM host depending on the VM profile
               disk type setting. If the VM disk type in the VM profile is set
               to localdisk, the image repository on the management node is
               checked. Otherwise, the vmdk directory on the VM host is checked.

=cut

sub does_image_exist {
	my $self = shift;
	if (ref($self) !~ /vmware/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}
	
	my $vmprofile_vmdisk = $self->data->get_vmhost_profile_vmdisk() || return;
	
	# Check if the VM host is using local or network-based disk
	if ($vmprofile_vmdisk eq "localdisk") {
		# Local disk - check size of directory in image repository
		my $repository_vmdk_file_path = $self->get_repository_vmdk_file_path() || return;
		notify($ERRORS{'DEBUG'}, 0, "vm disk type is $vmprofile_vmdisk, checking if vmdk file exists in image repository: $repository_vmdk_file_path");
		
		# Remove any trailing slashes and separate the directory path and name pattern
		$repository_vmdk_file_path =~ s/\/*$//g;
		my ($directory_path, $name_pattern) = $repository_vmdk_file_path =~ /^(.*)\/([^\/]*)/g;
		
		# Check if the file or directory exists
		(my ($exit_status, $output) = run_command("find \"$directory_path\" -iname \"$name_pattern\"")) || return;
		if (!grep(/find: /i, @$output) && grep(/$directory_path/i, @$output)) {
			notify($ERRORS{'DEBUG'}, 0, "file exists in repository: $repository_vmdk_file_path");
			return 1;
		}
		elsif (grep(/find: /i, @$output) && !grep(/no such file/i, @$output)) {
			notify($ERRORS{'WARNING'}, 0, "failed to determine if file exists in repository: $repository_vmdk_file_path, output:\n" . join("\n", @$output));
			return;
		}
		else {
			notify($ERRORS{'DEBUG'}, 0, "file does NOT exist in image repository: $repository_vmdk_file_path");
			return 0;
		}
	}
	else {
		notify($ERRORS{'DEBUG'}, 0, "vm disk type is $vmprofile_vmdisk, checking if file exists on VM host");
		return $self->vmhost_os->file_exists($self->get_vmdk_file_path_nonpersistent());
	}
}

#/////////////////////////////////////////////////////////////////////////////

=head2 get_vmdk_parameter_value

 Parameters  : $vmdk_parameter
 Returns     : string
 Description : Opens the .vmdk file, searches for the parameter argument, and
               returns the value for the parameter.  Example:
               vmdk file contains: ddb.adapterType = "buslogic"
               get_vmdk_parameter_value('adapterType') returns buslogic

=cut

sub get_vmdk_parameter_value {
	my $self = shift;
	if (ref($self) !~ /vmware/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}
	
	# Get the .vmdk parameter argument to search for
	my $vmdk_parameter = shift;
	if (!$vmdk_parameter) {
		notify($ERRORS{'WARNING'}, 0, "vmdk parameter name argument was not specified");
		return;
	}
	
	my $image_repository_vmdk_file_path = $self->get_repository_vmdk_file_path() || return;
	notify($ERRORS{'DEBUG'}, 0, "attempting to locate $vmdk_parameter value in $image_repository_vmdk_file_path");
	
	# Open the vmdk file for reading
	if (open FILE, "<", $image_repository_vmdk_file_path) {
		notify($ERRORS{'DEBUG'}, 0, "opened vmdk file for reading: $image_repository_vmdk_file_path");
	}
	else {
		notify($ERRORS{'WARNING'}, 0, "unable to open vmdk file for reading: $image_repository_vmdk_file_path");
		return;
	}
	
	# Read the file line by line - do not read the file all at once
	# The vmdk file may be very large depending on the type - it may not be split up into a descriptor file and extents
	# If the vmdk file isn't split, the descriptor section will be at the beginning
	my $line_count = 0;
	my $value;
	while ($line_count < 100) {
		$line_count++;
		my $line = <FILE>;
		chomp $line;
		
		# Ignore comment lines
		next if ($line =~ /^\s*#/);
		
		# Check if the line contains the parameter name
		if ($line =~ /(^|\.)$vmdk_parameter[\s=]+/i) {
			notify($ERRORS{'DEBUG'}, 0, "found line containing $vmdk_parameter: '$line'");
			
			# Extract the value from the line
			($value) = $line =~ /\"(.+)\"/;
			last;
		}
	}
	
	close FILE;
	
	if (defined($value)) {
		notify($ERRORS{'DEBUG'}, 0, "found $vmdk_parameter value in vmdk file: '$value'");
		return $value;
	}
	else {
		notify($ERRORS{'WARNING'}, 0, "did not find $vmdk_parameter value in vmdk file");
		return;
	}
}

#/////////////////////////////////////////////////////////////////////////////

=head2 get_vm_disk_adapter_type

 Parameters  : none
 Returns     : string
 Description : Returns the adapterType value in the vmdk file. Possible return
               values:
               -ide
               -lsilogic
               -buslogic

=cut

sub get_vm_disk_adapter_type {
	my $self = shift;
	if (ref($self) !~ /vmware/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}
	
	if ($self->api->can("get_virtual_disk_controller_type")) {
		return $self->api->get_virtual_disk_controller_type($self->get_vmdk_file_path());
	}
	else {
		return $self->get_vmdk_parameter_value('adapterType');
	}
}

#/////////////////////////////////////////////////////////////////////////////

=head2 get_vm_virtual_hardware_version

 Parameters  : none
 Returns     : string
 Description : Returns the virtualHWVersion value in the vmdk file.

=cut

sub get_vm_virtual_hardware_version {
	my $self = shift;
	if (ref($self) !~ /vmware/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}
	
	if ($self->api->can("get_virtual_disk_hardware_version")) {
		return $self->api->get_virtual_disk_hardware_version($self->get_vmdk_file_path());
	}
	else {
		return $self->get_vmdk_parameter_value('virtualHWVersion');
	}
}

#/////////////////////////////////////////////////////////////////////////////

=head2 get_vm_os_configuration

 Parameters  : none
 Returns     : hash
 Description : Returns the information stored in %VM_OS_CONFIGURATION for
               the guest OS. The guest OS type, OS name, and archictecture are
               used to determine the appropriate guestOS and ethernet-virtualDev
               values to be used in the vmx file.

=cut

sub get_vm_os_configuration {
	my $self = shift;
	if (ref($self) !~ /vmware/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}
	
	# Return previously retrieved data if it exists
	return $self->{vm_os_configuration} if $self->{vm_os_configuration};
	
	my $image_os_type = $self->data->get_image_os_type() || return;
	my $image_os_name = $self->data->get_image_os_name() || return;
	my $image_architecture = $self->data->get_image_architecture() || return;
	
	# Figure out the key name in the %VM_OS_CONFIGURATION hash for the guest OS
	my $vm_os_configuration_key;
	if ($image_os_type =~ /linux/i) {
		$vm_os_configuration_key = "linux-$image_architecture";
	}
	elsif ($image_os_type =~ /windows/i) {
		my $regex = 'xp|2003|2008|vista|7';
		$image_os_name =~ /($regex)/i;
		my $windows_product = $1;
		if (!$windows_product) {
			notify($ERRORS{'WARNING'}, 0, "unsupported Windows product: $image_os_name, it does not contain ($regex), using default values for Windows");
			$windows_product = 'windows';
		}
		$vm_os_configuration_key = "$windows_product-$image_architecture";
	}
	else {
		notify($ERRORS{'WARNING'}, 0, "unsupported OS type: $image_os_type, using default values");
		$vm_os_configuration_key = "default-$image_architecture";
	}
	
	# Retrieve the information from the hash, set an object variable
	$self->{vm_os_configuration} = $VM_OS_CONFIGURATION{$vm_os_configuration_key};
	if ($self->{vm_os_configuration}) {
		notify($ERRORS{'DEBUG'}, 0, "found vm OS configuration ($vm_os_configuration_key):\n" . format_data($self->{vm_os_configuration}));
		return $self->{vm_os_configuration};
	}
	else {
		notify($ERRORS{'DEBUG'}, 0, "failed to find vm OS configuration for $vm_os_configuration_key");
		return;
	}
}

#/////////////////////////////////////////////////////////////////////////////

=head2 get_vm_guest_os

 Parameters  : none
 Returns     : string
 Description : Returns the appropriate guestOS value to be used in the vmx file.

=cut

sub get_vm_guest_os {
	my $self = shift;
	if (ref($self) !~ /vmware/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}
	
	my $vm_os_configuration = $self->get_vm_os_configuration() || return;
	return $vm_os_configuration->{"guestOS"};
}

#/////////////////////////////////////////////////////////////////////////////

=head2 get_vm_ethernet_adapter_type

 Parameters  : none
 Returns     : string
 Description : Returns the appropriate ethernet virtualDev value to be used in
               the vmx file.

=cut

sub get_vm_ethernet_adapter_type {
	my $self = shift;
	if (ref($self) !~ /vmware/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}
	
	my $vm_os_configuration = $self->get_vm_os_configuration() || return;
	return $vm_os_configuration->{"ethernet-virtualDev"};
}

#/////////////////////////////////////////////////////////////////////////////

=head2 get_vm_ram

 Parameters  : none
 Returns     : integer
 Description : Returns the amount of RAM in MB to be assigned to the VM. The
               VCL minimum RAM value configured for the image is used as the
               base value.
               
               The RAM setting in the vmx file must be a multiple of 4. The
               minimum RAM value is checked to make sure it is a multiple of 4.
               If not, the value is rounded down.
               
               The RAM value is also checked to make sure it is not lower than
               512 MB. If so, 512 MB is returned.

=cut

sub get_vm_ram {
	my $self = shift;
	if (ref($self) !~ /vmware/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}
	
	my $minimum_vm_ram_mb = 512;
	
	# Get the image minram setting
	my $image_minram_mb = $self->data->get_image_minram();
	if (!defined($image_minram_mb)) {
		notify($ERRORS{'WARNING'}, 0, "failed to retrieve image minram value");
		return;
	}
	
	# Make sure VM ram is a multiple of 4
	if ($image_minram_mb % 4) {
		my $image_minram_mb_original = $image_minram_mb;
		$image_minram_mb -= ($image_minram_mb % 4);
		notify($ERRORS{'DEBUG'}, 0, "image minram value is not a multiple of 4: $image_minram_mb_original, adjusting to $image_minram_mb");
	}
	
	# Check if the image setting is too low
	if ($image_minram_mb < $minimum_vm_ram_mb) {
		notify($ERRORS{'DEBUG'}, 0, "image ram setting is too low: $image_minram_mb MB, $minimum_vm_ram_mb MB will be used");
		return $minimum_vm_ram_mb;
	}
	
	return $image_minram_mb;
}

#/////////////////////////////////////////////////////////////////////////////

=head2 get_lockfile

 Parameters  : $file_path, $total_wait_seconds (optional), $attempt_delay_seconds (optional)
 Returns     : filehandle
 Description : Attempts to open and obtain an exclusive lock on the file
               specified by the file path argument. If unable to obtain an
               exclusive lock, it will wait up to the value specified by the
               total wait seconds argument (default: 30 seconds). The number of
               seconds to wait in between retries can be specified (default: 15
               seconds).

=cut

sub get_lockfile {
	my $self = shift;
	if (ref($self) !~ /Module/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}
	
	# Get the file path argument
	my ($file_path, $total_wait_seconds, $attempt_delay_seconds) = @_;
	if (!$file_path) {
		notify($ERRORS{'WARNING'}, 0, "file path argument was not supplied");
		return;
	}
	
	# Set the wait defaults if not supplied as arguments
	$total_wait_seconds = 30 if !$total_wait_seconds;
	$attempt_delay_seconds = 5 if !$attempt_delay_seconds;
	
	# Attempt to open the file
	notify($ERRORS{'DEBUG'}, 0, "attempting to open file to be exclusively locked: $file_path");
	my $file_handle = new IO::File($file_path, O_RDONLY | O_CREAT);
	if (!$file_handle) {
		notify($ERRORS{'WARNING'}, 0, "failed to open file to be exclusively locked: $file_path, reason: $!");
		return;
	}
	my $fileno = $file_handle->fileno;
	notify($ERRORS{'DEBUG'}, 0, "opened file to be exclusively locked: $file_path");
	
	# Store the fileno and path in %ENV so we can retrieve the path later on
	$ENV{fileno}{$fileno} = $file_path;
	
	# Attempt to lock the file
	my $wait_message = "attempting to obtain lock on file: $file_path";
	if ($self->code_loop_timeout(sub{flock($file_handle, LOCK_EX|LOCK_NB)}, [], $wait_message, $total_wait_seconds, $attempt_delay_seconds)) {
		notify($ERRORS{'DEBUG'}, 0, "obtained an exclusive lock on file: $file_path");
	}
	else {
		notify($ERRORS{'DEBUG'}, 0, "failed to obtain lock on file: $file_path");
		return;
	}
	
	# Store the file handle as a variable and return it
	return $file_handle;
}

#/////////////////////////////////////////////////////////////////////////////

=head2 release_lockfile

 Parameters  : $file_handle
 Returns     : boolean
 Description : Closes the lockfile handle specified by the argument.

=cut

sub release_lockfile {
	my $self = shift;
	if (ref($self) !~ /Module/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}
	
	# Get the file handle argument
	my ($file_handle) = @_;
	if (!$file_handle) {
		notify($ERRORS{'WARNING'}, 0, "file handle argument was not supplied");
		return;
	}
	
	# Make sure the file handle is opened
	my $fileno = $file_handle->fileno;
	if (!$fileno) {
		notify($ERRORS{'WARNING'}, 0, "file handle is not opened");
		return;
	}
	
	# Get the file path previously stored in %ENV
	my $file_path = $ENV{fileno}{$fileno} || 'unknown';
	
	# Close the file
	if (close($file_handle)) {
		notify($ERRORS{'DEBUG'}, 0, "closed file handle: $file_path");
	}
	else {
		notify($ERRORS{'WARNING'}, 0, "failed to close file handle: $file_path, reason: $!");
		return;
	}
	
	delete $ENV{fileno}{$fileno};
	return 1;
}

#/////////////////////////////////////////////////////////////////////////////

=head2 get_vmx_file_paths

 Parameters  : none
 Returns     : array
 Description : Finds vmx files under the vmx base directory on the VM host.
               Returns an array containing the file paths.

=cut

sub get_vmx_file_paths {
	my $self = shift;
	if (ref($self) !~ /vmware/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}
	
	my $vmx_base_directory_path = $self->get_vmx_base_directory_path() || return;
	
	(my @vmx_paths = $self->vmhost_os->find_files($vmx_base_directory_path, "*.vmx")) || return;
	notify($ERRORS{'DEBUG'}, 0, "found " . scalar(@vmx_paths) . " vmx files on VM host:\n" . join("\n", @vmx_paths));
	return @vmx_paths;
}

#/////////////////////////////////////////////////////////////////////////////

=head2 get_vmx_info

 Parameters  : none
 Returns     : hash
 Description : Finds vmx files under the vmx base directory on the VM host,
               parses each vmx file, and returns a hash containing the info for
               each vmx file found. The hash keys are the vmx file paths.  Example:
               |--{/vmfs/volumes/nfs-vmpath/vm-ark-mcnc-9_1635-v0/vm-ark-mcnc-9_1635-v0.vmx}{computer_id} = '2008'
               |--{/vmfs/volumes/nfs-vmpath/vm-ark-mcnc-9_1635-v0/vm-ark-mcnc-9_1635-v0.vmx}{displayname} = 'vm-ark-mcnc-9 (nonpersistent: vmwarewin2008-enterprisex86_641635-v0)'
               |--{/vmfs/volumes/nfs-vmpath/vm-ark-mcnc-9_1635-v0/vm-ark-mcnc-9_1635-v0.vmx}{ethernet0.address} = '00:50:56:03:54:11'
               |--{/vmfs/volumes/nfs-vmpath/vm-ark-mcnc-9_1635-v0/vm-ark-mcnc-9_1635-v0.vmx}{ethernet0.addresstype} = 'static'
               |--{/vmfs/volumes/nfs-vmpath/vm-ark-mcnc-9_1635-v0/vm-ark-mcnc-9_1635-v0.vmx}{ethernet0.virtualdev} = 'e1000'
               |--{/vmfs/volumes/nfs-vmpath/vm-ark-mcnc-9_1635-v0/vm-ark-mcnc-9_1635-v0.vmx}{ethernet0.vnet} = 'Private'
               |--{/vmfs/volumes/nfs-vmpath/vm-ark-mcnc-9_1635-v0/vm-ark-mcnc-9_1635-v0.vmx}{guestos} = 'winserver2008enterprise-32'
               |--{/vmfs/volumes/nfs-vmpath/vm-ark-mcnc-9_1635-v0/vm-ark-mcnc-9_1635-v0.vmx}{scsi0.present} = 'TRUE'
               |--{/vmfs/volumes/nfs-vmpath/vm-ark-mcnc-9_1635-v0/vm-ark-mcnc-9_1635-v0.vmx}{scsi0.virtualdev} = 'lsiLogic'
               |--{/vmfs/volumes/nfs-vmpath/vm-ark-mcnc-9_1635-v0/vm-ark-mcnc-9_1635-v0.vmx}{scsi0:0.devicetype} = 'scsi-hardDisk'
               |--{/vmfs/volumes/nfs-vmpath/vm-ark-mcnc-9_1635-v0/vm-ark-mcnc-9_1635-v0.vmx}{scsi0:0.filename} = '/vmfs/volumes/nfs-datastore/vmwarewin2008-enterprisex86_641635-v0/vmwarewin2008-enterprisex86_641635-v0.vmdk'
               |--{/vmfs/volumes/nfs-vmpath/vm-ark-mcnc-9_1635-v0/vm-ark-mcnc-9_1635-v0.vmx}{scsi0:0.mode} = 'independent-nonpersistent'
               |--{/vmfs/volumes/nfs-vmpath/vm-ark-mcnc-9_1635-v0/vm-ark-mcnc-9_1635-v0.vmx}{scsi0:0.present} = 'TRUE'
               |--{/vmfs/volumes/nfs-vmpath/vm-ark-mcnc-9_1635-v0/vm-ark-mcnc-9_1635-v0.vmx}{virtualhw.version} = '4'
               |--{/vmfs/volumes/nfs-vmpath/vm-ark-mcnc-9_1635-v0/vm-ark-mcnc-9_1635-v0.vmx}{vmx_directory} = '/vmfs/volumes/nfs-vmpath/vm-ark-mcnc-9_1635-v0'
               |--{/vmfs/volumes/nfs-vmpath/vm-ark-mcnc-9_1635-v0/vm-ark-mcnc-9_1635-v0.vmx}{vmx_file_name} = 'vm-ark-mcnc-9_1635-v0.vmx'
                  |--{/vmfs/volumes/nfs-vmpath/vm-ark-mcnc-9_1635-v0/vm-ark-mcnc-9_1635-v0.vmx}{vmdk}{scsi0:0}{devicetype} = 'scsi-hardDisk'
                  |--{/vmfs/volumes/nfs-vmpath/vm-ark-mcnc-9_1635-v0/vm-ark-mcnc-9_1635-v0.vmx}{vmdk}{scsi0:0}{mode} = 'independent-nonpersistent'
                  |--{/vmfs/volumes/nfs-vmpath/vm-ark-mcnc-9_1635-v0/vm-ark-mcnc-9_1635-v0.vmx}{vmdk}{scsi0:0}{present} = 'TRUE'
                  |--{/vmfs/volumes/nfs-vmpath/vm-ark-mcnc-9_1635-v0/vm-ark-mcnc-9_1635-v0.vmx}{vmdk}{scsi0:0}{vmdk_directory_path} = '/vmfs/volumes/nfs-datastore/vmwarewin2008-enterprisex86_641635-v0'
                  |--{/vmfs/volumes/nfs-vmpath/vm-ark-mcnc-9_1635-v0/vm-ark-mcnc-9_1635-v0.vmx}{vmdk}{scsi0:0}{vmdk_file_name} = 'vmwarewin2008-enterprisex86_641635-v0'
                  |--{/vmfs/volumes/nfs-vmpath/vm-ark-mcnc-9_1635-v0/vm-ark-mcnc-9_1635-v0.vmx}{vmdk}{scsi0:0}{vmdk_file_path} = '/vmfs/volumes/nfs-datastore/vmwarewin2008-enterprisex86_641635-v0/vmwarewin2008-enterprisex86_641635-v0.vmdk'

=cut

sub get_vmx_info {
	my $self = shift;
	if (ref($self) !~ /vmware/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}
	
	# Get the .vmx paths on the VM host
	my @vmx_file_paths = @_;
	@vmx_file_paths = $self->get_vmx_file_paths() if !@vmx_file_paths;
	return if !@vmx_file_paths;
	
	my %vmx_info;
	for my $vmx_file_path (@vmx_file_paths) {
		(my @vmx_contents = $self->vmhost_os->get_file_contents($vmx_file_path)) || next;
		
		for my $vmx_line (@vmx_contents) {
			next if $vmx_line !~ /=/;
			my ($property, $value) = $vmx_line =~ /[#\s"]*(.*[^\s])[\s"]*=[\s"]*(.*)"/g;
			$vmx_info{$vmx_file_path}{lc($property)} = $value;
			
			if ($property =~ /((?:ide|scsi)\d+:\d+)\.(.*)/) {
				$vmx_info{$vmx_file_path}{vmdk}{lc($1)}{lc($2)} = $value;
			}
		}
		
		# Get the vmx file name and directory from the full path
		($vmx_info{$vmx_file_path}{vmx_file_name}) = $vmx_file_path =~ /([^\/]+)$/;
		($vmx_info{$vmx_file_path}{vmx_directory}) = $vmx_file_path =~ /(.*)\/[^\/]+$/;
		
		# Loop through the storage identifiers (idex:x or scsix:x lines found)
		# Find the ones with a fileName property set to a .vmdk path
		for my $storage_identifier (keys %{$vmx_info{$vmx_file_path}{vmdk}}) {
			my $vmdk_file_path = $vmx_info{$vmx_file_path}{vmdk}{$storage_identifier}{filename};
			if (!$vmdk_file_path) {
				notify($ERRORS{'DEBUG'}, 0, "ignoring $storage_identifier, filename property not set");
				delete $vmx_info{$vmx_file_path}{vmdk}{$storage_identifier};
				next;
			}
			elsif ($vmdk_file_path !~ /\.vmdk$/i) {
				notify($ERRORS{'DEBUG'}, 0, "ignoring $storage_identifier, filename property does not end with .vmdk: $vmdk_file_path");
				delete $vmx_info{$vmx_file_path}{vmdk}{$storage_identifier};
				next;
			}
			
			# Check if mode is set
			my $vmdk_mode = $vmx_info{$vmx_file_path}{vmdk}{$storage_identifier}{mode};
			if (!$vmdk_mode) {
				notify($ERRORS{'DEBUG'}, 0, "$storage_identifier mode property not set, setting default value: persistent");
				$vmx_info{$vmx_file_path}{vmdk}{$storage_identifier}{mode} = 'persistent';
			}
			
			# Check if the vmdk path begins with a /, if not, prepend the .vmx directory path
			if ($vmdk_file_path !~ /^\//) {
				my $vmdk_file_path_original = $vmdk_file_path;
				$vmx_info{$vmx_file_path}{vmdk}{$storage_identifier}{filename} = "$vmx_info{$vmx_file_path}{vmx_directory}\/$vmdk_file_path";
				$vmdk_file_path = $vmx_info{$vmx_file_path}{vmdk}{$storage_identifier}{filename};
				notify($ERRORS{'DEBUG'}, 0, "vmdk path appears to be relative: $vmdk_file_path_original, prepending the vmx directory: $vmdk_file_path");
			}
			
			# Get the directory path
			my ($vmdk_directory_path) = $vmdk_file_path =~ /(.*)\/[^\/]+$/;
			if (!$vmdk_directory_path) {
				notify($ERRORS{'DEBUG'}, 0, "unable to determine vmdk directory from path: $vmdk_file_path");
				delete $vmx_info{$vmx_file_path}{vmdk}{$storage_identifier};
				next;
			}
			else {
				$vmx_info{$vmx_file_path}{vmdk}{$storage_identifier}{vmdk_directory_path} = $vmdk_directory_path;
			}
			
			$vmx_info{$vmx_file_path}{vmdk}{$storage_identifier}{vmdk_file_path} = $vmdk_file_path;
			delete $vmx_info{$vmx_file_path}{vmdk}{$storage_identifier}{filename};
			($vmx_info{$vmx_file_path}{vmdk}{$storage_identifier}{vmdk_file_name}) = $vmdk_file_path =~ /([^\/]+)\.vmdk$/i;
		}
	}
	
	$self->{host_vmx_info} = \%vmx_info;
	return \%vmx_info;
}

#/////////////////////////////////////////////////////////////////////////////

=head2 delete_vm

 Parameters  : $vmx_file_path
 Returns     : boolean
 Description : Deletes the VM specified by the vmx file path argument. The VM is
               first unregistered and the vmx directory is deleted. The vmdk
               files used by the VM are deleted if the disk type is persistent.

=cut

sub delete_vm {
	my $self = shift;
	if (ref($self) !~ /vmware/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}
	
	# Get the vmx file path argument
	my $vmx_file_path = shift;
	if (!$vmx_file_path) {
		notify($ERRORS{'WARNING'}, 0, "vmx file path argument was not supplied");
		return;
	}
	
	# Get the vmx info
	my $vmx_info = $self->get_vmx_info($vmx_file_path)->{$vmx_file_path} || return;
	my $vmx_directory_path = $vmx_info->{vmx_directory};
	
	# Unregister the VM
	if (!$self->api->vm_unregister($vmx_file_path)) {
		notify($ERRORS{'WARNING'}, 0, "failed to unregister VM: $vmx_file_path, VM not deleted");
		return;
	}
	
	for my $storage_identifier (keys %{$vmx_info->{vmdk}}) {
		my $vmdk_file_path = $vmx_info->{vmdk}{$storage_identifier}{vmdk_file_path};
		my $vmdk_file_name = $vmx_info->{vmdk}{$storage_identifier}{vmdk_file_name};
		my $vmdk_directory_path = $vmx_info->{vmdk}{$storage_identifier}{vmdk_directory_path};
		my $vmdk_mode = $vmx_info->{vmdk}{$storage_identifier}{mode};
		
		notify($ERRORS{'DEBUG'}, 0, "$storage_identifier:\n
				 vmdk file name: $vmdk_file_name
				 vmdk file path: $vmdk_file_path
				 vmdk directory path: $vmdk_directory_path
				 mode: $vmdk_mode");
		
		if ($vmdk_mode =~ /^(independent-)?persistent/) {
			notify($ERRORS{'DEBUG'}, 0, "mode of vmdk files for VM $vmx_file_path is $vmdk_mode, vmdk directory will be deleted: $vmdk_directory_path");
			$self->vmhost_os->delete_file($vmdk_directory_path) || return;
		}
		else {
			notify($ERRORS{'DEBUG'}, 0, "mode of vmdk files for VM $vmx_file_path is $vmdk_mode, vmdk directory will NOT be deleted: $vmdk_directory_path");
		}
	}
	
	# Delete the vmx directory
	notify($ERRORS{'DEBUG'}, 0, "attempting to delete vmx directory: $vmx_directory_path");
	if (!$self->vmhost_os->delete_file($vmx_directory_path)) {
		notify($ERRORS{'WARNING'}, 0, "failed to delete VM: $vmx_file_path, vmx directory could not be deleted: $vmx_directory_path");
		return;
	}
	
	notify($ERRORS{'DEBUG'}, 0, "deleted VM: $vmx_file_path");
	return 1;
}

#/////////////////////////////////////////////////////////////////////////////

=head2 get_vm_additional_vmdk_bytes_required

 Parameters  : none
 Returns     : integer
 Description : Checks if additional space is required for the VM's vmdk files
               before a VM is loaded by checking if the vmdk already exists on
               the VM host. If the vmdk does not exist, the image size is
               returned.

=cut

sub get_vm_additional_vmdk_bytes_required {
	my $self = shift;
	if (ref($self) !~ /vmware/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}
	
	my $additional_bytes_required = 0;
	
	# Check if the .vmdk files already exist on the host
	my $host_vmdk_file_exists = $self->vmhost_os->file_exists($self->get_vmdk_file_path());
	my $image_size = $self->get_image_size() || return;
	if (!defined $host_vmdk_file_exists) {
		notify($ERRORS{'WARNING'}, 0, "failed to determine if vmdk files already exist on VM host");
		return;
	}
	if ($host_vmdk_file_exists == 0) {
		$additional_bytes_required += $image_size;
		notify($ERRORS{'DEBUG'}, 0, "$image_size additional bytes required because vmdk files do NOT already exist on VM host");
	}
	else {
		notify($ERRORS{'DEBUG'}, 0, "no additional space required for vmdk files because they already exist on VM host");
	}
	
	my $additional_mb_required = format_number($additional_bytes_required / 1024 / 1024);
	my $additional_gb_required = format_number($additional_bytes_required / 1024 / 1024 / 1024);
	notify($ERRORS{'DEBUG'}, 0, "VM requires appoximately $additional_bytes_required additional bytes ($additional_mb_required MB, $additional_gb_required GB) of disk space on the VM host for the vmdk directory");
	return $additional_bytes_required;
}

#/////////////////////////////////////////////////////////////////////////////

=head2 get_vm_additional_vmx_bytes_required

 Parameters  : none
 Returns     : integer
 Description : Checks if additional space is required for the files that will be
               stored in the VM's vmx directory before a VM is loaded. Space is
               required for the VM's vmem file. This is calculated by retrieving
               the RAM setting for the VM. Space is required for REDO files if
               the virtual disk is non-persistent. This is estimated to be 1/4
               the disk size.

=cut

sub get_vm_additional_vmx_bytes_required {
	my $self = shift;
	if (ref($self) !~ /vmware/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}
	
	my $additional_bytes_required = 0;
	
	# Add the amount of RAM assigned to the VM to the bytes required for the vmem file
	my $vm_ram_mb = $self->get_vm_ram() || return;
	my $vm_ram_bytes = ($vm_ram_mb * 1024 * 1024);
	$additional_bytes_required += $vm_ram_bytes;
	notify($ERRORS{'DEBUG'}, 0, "$vm_ram_bytes additional bytes required for VM vmem file");
	
	# Check if the VM is persistent
	# If non-persistent, add bytes for the REDO files
	if ($self->is_vm_persistent()) {
		notify($ERRORS{'DEBUG'}, 0, "no additional space required for REDO files because VM disk mode is persistent");
	}
	else {
		# Estimate that REDO files will grow to 1/4 the image size
		my $image_size = $self->get_image_size() || return;
		my $redo_size = int($image_size / 4);
		$additional_bytes_required += $redo_size;
		notify($ERRORS{'DEBUG'}, 0, "$redo_size additional bytes required for REDO files because VM disk mode is NOT persistent");
	}
	
	my $additional_mb_required = format_number($additional_bytes_required / 1024 / 1024);
	my $additional_gb_required = format_number($additional_bytes_required / 1024 / 1024 / 1024);
	notify($ERRORS{'DEBUG'}, 0, "VM requires appoximately $additional_bytes_required additional bytes ($additional_mb_required MB, $additional_gb_required GB) of disk space on the VM host for the vmx directory");
	return $additional_bytes_required;
}

#/////////////////////////////////////////////////////////////////////////////

=head2 set_vmx_file_path

 Parameters  : $vmx_file_path
 Returns     : boolean
 Description : Sets the vmx path into %ENV so that the default values are
               overridden when the various get_vmx_ subroutines are called. This
               is useful when a base image is being captured. The vmx file does
               not need to be in the expected directory nor does it need to be
               named anything particular. The code locates the vmx file and then
               saves the non-default path in this object so that capture works
               regardless of the vmx path/name.

=cut

sub set_vmx_file_path {
	my $self = shift;
	if (ref($self) !~ /vmware/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}
	
	# Get the vmx file path argument
	my $vmx_file_path = shift;
	if (!$vmx_file_path) {
		notify($ERRORS{'WARNING'}, 0, "vmx file path argument was not supplied");
		return;
	}
	
	delete $ENV{vmx_file_path};
	
	if ($vmx_file_path ne $self->get_vmx_file_path()) {
		notify($ERRORS{'DEBUG'}, 0, "vmx file path will be overridden, it does not match the expected path:
				 argument: $vmx_file_path
				 expected: " . $self->get_vmx_file_path());
	}
	else {
		return 1;
	}
	
	# Make sure the vmx file path begins with the vmx base directory
	my $vmx_base_directory_path = $self->get_vmx_base_directory_path() || return;
	if ($vmx_file_path !~ /^$vmx_base_directory_path/) {
		notify($ERRORS{'WARNING'}, 0, "unable to override vmx file path $vmx_file_path, it does not begin with the vmx base directory path: $vmx_base_directory_path");
		return;
	}
	
	# Make sure the vmx file path ends with .vmx
	if ($vmx_file_path !~ /\.vmx$/) {
		notify($ERRORS{'WARNING'}, 0, "unable to override vmx file path $vmx_file_path, it does not end with .vmx");
		return;
	}
	
	# Make sure the vmx file path contains a file name
	if ($vmx_file_path !~ /\/[^\/]+\.vmx$/) {
		notify($ERRORS{'WARNING'}, 0, "unable to override vmx file path $vmx_file_path, it does not contain a file name");
		return;
	}
	
	# Make sure the vmx file path contains an intermediate path
	if ($vmx_file_path !~ /^$vmx_base_directory_path\/.+\/[^\/]+\.vmx$/) {
		notify($ERRORS{'WARNING'}, 0, "unable to override vmx file path $vmx_file_path, it does not contain an intermediate path");
		return;
	}
	
	$ENV{vmx_file_path} = $vmx_file_path;
	notify($ERRORS{'OK'}, 0, "set overridden vmx location:\n" .
			 "vmx file path: $vmx_file_path\n" .
			 "vmx base directory path: " . $self->get_vmx_base_directory_path() . "\n" .
			 "vmx directory name: " . $self->get_vmx_directory_name() . "\n" .
			 "vmx directory path: " . $self->get_vmx_directory_path() . "\n" .
			 "vmx file name: " . $self->get_vmx_file_name() . "\n" .
			 "vmx file path: " . $self->get_vmx_file_path());
	
	return 1;
}

#/////////////////////////////////////////////////////////////////////////////

=head2 set_vmdk_file_path

 Parameters  : $vmx_file_path
 Returns     : 
 Description : Sets the vmdk path into %ENV so that the default values are
               overridden when the various get_vmdk_... subroutines are called.
               This is useful for base image imaging reservations if the
               code detects the vmdk path is not in the expected place.

=cut

sub set_vmdk_file_path {
	my $self = shift;
	if (ref($self) !~ /vmware/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}
	
	# Get the vmdk file path argument
	my $vmdk_file_path_argument = shift;
	if (!$vmdk_file_path_argument) {
		notify($ERRORS{'WARNING'}, 0, "vmdk file path argument was not supplied");
		return;
	}
	
	delete $ENV{vmdk_file_path};
	
	if ($vmdk_file_path_argument ne $self->get_vmdk_file_path()) {
		notify($ERRORS{'DEBUG'}, 0, "vmdk file path will be overridden, it does not match the expected path:
				 argument: $vmdk_file_path_argument
				 expected: " . $self->get_vmdk_file_path());
	}
	else {
		notify($ERRORS{'DEBUG'}, 0, "vmdk file path does not need to overridden, it matches the expected path: $vmdk_file_path_argument");
		return 1;
	}
	
	# Make sure the vmdk file path ends with .vmdk
	if ($vmdk_file_path_argument !~ /\.vmdk$/) {
		notify($ERRORS{'WARNING'}, 0, "unable to override vmdk file path $vmdk_file_path_argument, it does not end with .vmdk");
		return;
	}
	
	# Make sure the vmdk file path contains a file name
	if ($vmdk_file_path_argument !~ /\/[^\/]+\.vmdk$/) {
		notify($ERRORS{'WARNING'}, 0, "unable to override vmdk file path $vmdk_file_path_argument, it does not contain a file name");
		return;
	}
	
	$ENV{vmdk_file_path} = $vmdk_file_path_argument;
	
	my $vmdk_file_path = $self->get_vmdk_file_path() || 'UNAVAILABLE';
	my $vmdk_base_directory_path = $self->get_vmdk_base_directory_path() || 'UNAVAILABLE';
	my $vmdk_directory_name = $self->get_vmdk_directory_name() || 'UNAVAILABLE';
	my $vmdk_directory_path = $self->get_vmdk_directory_path() || 'UNAVAILABLE';
	my $vmdk_file_name = $self->get_vmdk_file_name() || 'UNAVAILABLE';
	
	if (grep(/UNAVAILABLE/, ($vmdk_file_path, $vmdk_base_directory_path, $vmdk_directory_name, $vmdk_directory_path, $vmdk_file_name))) {
		notify($ERRORS{'WARNING'}, 0, "failed to override vmdk location, some path components are unavailable:\n" .
			 "vmdk file path argument: $vmdk_file_path_argument\n" .
			 "vmdk file path: $vmdk_file_path\n" .
			 "vmdk base directory path: $vmdk_base_directory_path\n" .
			 "vmdk directory name: $vmdk_directory_name\n" .
			 "vmdk directory path: $vmdk_directory_path\n" .
			 "vmdk file name: $vmdk_file_name\n" .
			 "vmdk file path: $vmdk_file_path");
		return;
	}
	
	notify($ERRORS{'OK'}, 0, "set overridden vmdk location:\n" .
			 "vmdk file path argument: $vmdk_file_path_argument\n" .
			 "vmdk file path: $vmdk_file_path\n" .
			 "vmdk base directory path: $vmdk_base_directory_path\n" .
			 "vmdk directory name: $vmdk_directory_name\n" .
			 "vmdk directory path: $vmdk_directory_path\n" .
			 "vmdk file name: $vmdk_file_name\n" .
			 "vmdk file path: $vmdk_file_path");
	
	return 1;
}

#/////////////////////////////////////////////////////////////////////////////

=head2 rename_vmdk

 Parameters  : $source_vmdk_file_path, $destination_vmdk_file_path
 Returns     : boolean
 Description : Renames a vmdk. The full paths to the source and destination vmdk
               paths are required.

=cut

sub rename_vmdk {
	my $self = shift;
	if (ref($self) !~ /vmware/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}
	
	# Get the arguments
	my ($source_vmdk_file_path, $destination_vmdk_file_path) = @_;
	if (!$source_vmdk_file_path || !$destination_vmdk_file_path) {
		notify($ERRORS{'WARNING'}, 0, "source and destination vmdk file path arguments were not specified");
		return;
	}
	
	# Make sure the arguments end with .vmdk
	if ($source_vmdk_file_path !~ /\.vmdk$/i || $destination_vmdk_file_path !~ /\.vmdk$/i) {
		notify($ERRORS{'WARNING'}, 0, "source vmdk file path ($source_vmdk_file_path) and destination vmdk file path ($destination_vmdk_file_path) arguments do not end with .vmdk");
		return;
	}
	
	# Make sure the source vmdk file exists
	if (!$self->vmhost_os->file_exists($source_vmdk_file_path)) {
		notify($ERRORS{'WARNING'}, 0, "source vmdk file path does not exist: $source_vmdk_file_path");
		return;
	}
	
	# Make sure the destination vmdk file doesn't already exist
	if ($self->vmhost_os->file_exists($destination_vmdk_file_path)) {
		notify($ERRORS{'WARNING'}, 0, "destination vmdk file path already exists: $destination_vmdk_file_path");
		return;
	}
	
	notify($ERRORS{'DEBUG'}, 0, "attempting to rename vmdk: '$source_vmdk_file_path' --> '$destination_vmdk_file_path'");
	
	# Determine the destination vmdk directory path and create the directory
	my ($destination_vmdk_directory_path) = $destination_vmdk_file_path =~ /(.+)\/[^\/]+\.vmdk$/;
	if (!$destination_vmdk_directory_path) {
		notify($ERRORS{'WARNING'}, 0, "unable to determine destination vmdk directory path from vmdk file path: $destination_vmdk_file_path");
		return;
	}
	$self->vmhost_os->create_directory($destination_vmdk_directory_path) || return;
	
	# Check if the API object has implented a move_virtual_disk subroutine
	if ($self->api->can("move_virtual_disk")) {
		notify($ERRORS{'OK'}, 0, "attempting to rename vmdk file using API's 'move_virtual_disk' subroutine: $source_vmdk_file_path --> $destination_vmdk_file_path");
		
		if ($self->api->move_virtual_disk($source_vmdk_file_path, $destination_vmdk_file_path)) {
			notify($ERRORS{'OK'}, 0, "renamed vmdk using API's 'move_virtual_disk' subroutine: '$source_vmdk_file_path' --> '$destination_vmdk_file_path'");
			return 1;
		}
		else {
			notify($ERRORS{'DEBUG'}, 0, "failed to rename vmdk using API's 'move_virtual_disk' subroutine");
		}
	}
	else {
		notify($ERRORS{'DEBUG'}, 0, "'move_virtual_disk' subroutine has not been implemented by the API: " . ref($self->api));
	}
	
	# Check if the VM host OS object implements an execute subroutine and attempt to run vmware-vdiskmanager
	if ($self->vmhost_os->can("execute")) {
		notify($ERRORS{'OK'}, 0, "attempting to rename vmdk file using vmware-vdiskmanager: $source_vmdk_file_path --> $destination_vmdk_file_path");
		
		my $command = "vmware-vdiskmanager -n \"$source_vmdk_file_path\" \"$destination_vmdk_file_path\"";
		my ($exit_status, $output) = $self->vmhost_os->execute($command);
		
		if (!defined($output)) {
			notify($ERRORS{'WARNING'}, 0, "failed to execute 'vmware-vdiskmanager' command on VM host to rename vmdk file:\n$command");
		}
		elsif (grep(/success/i, @$output)) {
			notify($ERRORS{'OK'}, 0, "renamed vmdk file by executing 'vmware-vdiskmanager' command on VM host:\ncommand: $command\noutput: " . join("\n", @$output));
			return 1;
		}
		elsif (grep(/command not found/i, @$output)) {
			notify($ERRORS{'DEBUG'}, 0, "unable to rename vmdk using 'vmware-vdiskmanager' because the command is not available on VM host");
		}
		else {
			notify($ERRORS{'WARNING'}, 0, "failed to execute 'vmware-vdiskmanager' command on VM host to rename vmdk file:\n$command\noutput:\n" . join("\n", @$output));
		}
	}
	else {
		notify($ERRORS{'DEBUG'}, 0, "unable to execute 'vmware-vdiskmanager' on VM host because 'execute' subroutine has not been implemented by the VM host OS: " . ref($self->vmhost_os));
	}
	
	
	# Determine the source vmdk directory path
	my ($source_vmdk_directory_path) = $source_vmdk_file_path =~ /(.+)\/[^\/]+\.vmdk$/;
	if (!$source_vmdk_directory_path) {
		notify($ERRORS{'WARNING'}, 0, "unable to determine source vmdk directory path from vmdk file path: $source_vmdk_file_path");
		return;
	}
	
	# Determine the source vmdk file name
	my ($source_vmdk_file_name) = $source_vmdk_file_path =~ /\/([^\/]+\.vmdk)$/;
	if (!$source_vmdk_file_name) {
		notify($ERRORS{'WARNING'}, 0, "unable to determine source vmdk file name from vmdk file path: $source_vmdk_file_path");
		return;
	}
	
	# Determine the destination vmdk file name
	my ($destination_vmdk_file_name) = $destination_vmdk_file_path =~ /\/([^\/]+\.vmdk)$/;
	if (!$destination_vmdk_file_name) {
		notify($ERRORS{'WARNING'}, 0, "unable to determine destination vmdk file name from vmdk file path: $destination_vmdk_file_path");
		return;
	}
	
	# Determine the source vmdk file prefix - "vmwinxp-image.vmdk" --> "vmwinxp-image"
	my ($source_vmdk_file_prefix) = $source_vmdk_file_path =~ /\/([^\/]+)\.vmdk$/;
	if (!$source_vmdk_file_name) {
		notify($ERRORS{'WARNING'}, 0, "unable to determine source vmdk file prefix from vmdk file path: $source_vmdk_file_path");
		return;
	}
	
	# Determine the destination vmdk file prefix - "vmwinxp-image.vmdk" --> "vmwinxp-image"
	my ($destination_vmdk_file_prefix) = $destination_vmdk_file_path =~ /\/([^\/]+)\.vmdk$/;
	if (!$destination_vmdk_file_name) {
		notify($ERRORS{'WARNING'}, 0, "unable to determine destination vmdk file prefix from vmdk file path: $destination_vmdk_file_path");
		return;
	}
	
	# Find all of the source vmdk file paths including the extents
	my @source_vmdk_file_paths = $self->vmhost_os->find_files($source_vmdk_directory_path, "$source_vmdk_file_prefix*.vmdk");
	if (@source_vmdk_file_paths) {
		notify($ERRORS{'DEBUG'}, 0, "found " . scalar(@source_vmdk_file_paths) . " source vmdk file paths:\n" . join("\n", sort @source_vmdk_file_paths));
	}
	else {
		notify($ERRORS{'WARNING'}, 0, "failed to find source vmdk file paths, source vmdk directory: $source_vmdk_directory_path, source vmdk file pattern: $source_vmdk_file_prefix*.vmdk");
		return;
	}
	
	# Loop through the source vmdk paths, figure out the destination file path, rename the file
	my %renamed_file_paths;
	my $rename_error_occurred = 0;
	for my $source_vmdk_copy_path (@source_vmdk_file_paths) {
		# Determine the extent identifier = "vmwinxp-image-s003.vmdk" --> "s003"
		my ($extent_identifier) = $source_vmdk_copy_path =~ /\/$source_vmdk_file_prefix([^\/]*)\.vmdk$/;
		$extent_identifier = '' if !$extent_identifier;
		
		# Construct the destination vmdk path
		my $destination_vmdk_copy_path = "$destination_vmdk_directory_path/$destination_vmdk_file_prefix$extent_identifier.vmdk";
		
		# Call the VM host OS's move_file subroutine to rename the vmdk file
		notify($ERRORS{'DEBUG'}, 0, "attempting to rename vmdk file:\n'$source_vmdk_copy_path' --> '$destination_vmdk_copy_path'");
		if (!$self->vmhost_os->move_file($source_vmdk_copy_path, $destination_vmdk_copy_path)) {
			notify($ERRORS{'WARNING'}, 0, "failed to rename vmdk file: '$source_vmdk_copy_path' --> '$destination_vmdk_copy_path'");
			$rename_error_occurred = 1;
			last;
		}
		
		# Add the source and destination vmdk file paths to a hash which will be used in case an error occurs and the files need to be reverted back to their original names
		$renamed_file_paths{$source_vmdk_copy_path} = $destination_vmdk_copy_path;

		# Delay next rename or else VMware may crash - "[2010-05-24 05:59:01.267 'App' 3083897744 error] Caught signal 11"
		sleep 5;
	}
	
	# If multiple vmdk file paths were found, edit the base vmdk file and update the extents
	# Don't do this if a single vmdk file was found because it will be very large and won't contain the extent information
	# This could happen if a virtual disk is in raw format
	if ($rename_error_occurred) {
		notify($ERRORS{'DEBUG'}, 0, "vmdk file extents not updated because an error occurred moving the files");
	}
	elsif (scalar(@source_vmdk_file_paths) > 1) {
		# Attempt to retrieve the contents of the base vmdk file
		if (my @vmdk_file_contents = $self->vmhost_os->get_file_contents($destination_vmdk_file_path)) {
			notify($ERRORS{'DEBUG'}, 0, "retrieved vmdk file contents: '$destination_vmdk_file_path'\n" . join("\n", @vmdk_file_contents));
			
			# Loop through each line of the base vmdk file - replace the source vmdk file prefix with the destination vmdk file prefix
			my @updated_vmdk_file_contents;
			for my $vmdk_line (@vmdk_file_contents) {
				chomp $vmdk_line;
				(my $updated_vmdk_line = $vmdk_line) =~ s/($source_vmdk_file_prefix)([^\/]*\.vmdk)/$destination_vmdk_file_prefix$2/;
				if ($updated_vmdk_line ne $vmdk_line) {
					notify($ERRORS{'DEBUG'}, 0, "updating line in vmdk file:\n'$vmdk_line' --> '$updated_vmdk_line'");
				}
				push @updated_vmdk_file_contents, $updated_vmdk_line;
			}
			notify($ERRORS{'DEBUG'}, 0, "updated vmdk file contents: '$destination_vmdk_file_path'\n" . join("\n", @updated_vmdk_file_contents));
			
			# Create a temp file to store the update vmdk contents, this temp file will be copied to the VM host
			my ($temp_file_handle, $temp_file_path) = tempfile(CLEANUP => 1, SUFFIX => '.vmdk');
			if ($temp_file_handle && $temp_file_path) {
				# Write the contents to the temp file
				print $temp_file_handle join("\n", @updated_vmdk_file_contents);
				notify($ERRORS{'DEBUG'}, 0, "wrote updated vmdk contents to temp file: $temp_file_path");
				$temp_file_handle->close;
				
				# Copy the temp file to the VM host overwriting the original vmdk file
				if ($self->vmhost_os->copy_file_to($temp_file_path, $destination_vmdk_file_path)) {
					notify($ERRORS{'DEBUG'}, 0, "copied temp file containing updated vmdk contents to VM host:\n'$temp_file_path' --> '$destination_vmdk_file_path'");
				}
				else {
					notify($ERRORS{'WARNING'}, 0, "failed to copy temp file containing updated vmdk contents to VM host:\n'$temp_file_path' --> '$destination_vmdk_file_path'");
					$rename_error_occurred = 1;
				}
			}
			else {
				notify($ERRORS{'WARNING'}, 0, "failed to create temp file to store updated vmdk contents which will be copied to the VM host");
				$rename_error_occurred = 1;
			}
		}
		else {
			notify($ERRORS{'WARNING'}, 0, "failed to retrieve vmdk file contents: '$destination_vmdk_file_path'");
			$rename_error_occurred = 1;
		}
	}
	else {
		notify($ERRORS{'DEBUG'}, 0, "vmdk file extents not updated because a single source vmdk file was found");
	}
	
	# Check if an error occurred, revert the file renames if necessary
	if ($rename_error_occurred) {
		for my $destination_vmdk_revert_path (sort keys(%renamed_file_paths)) {
			my $source_vmdk_revert_path = $renamed_file_paths{$destination_vmdk_revert_path};
			
			# Call the VM host OS's move_file subroutine to rename the vmdk file back to what it was originally
			notify($ERRORS{'DEBUG'}, 0, "attempting to revert the vmdk file move:\n'$source_vmdk_revert_path' --> '$destination_vmdk_revert_path'");
			if (!$self->vmhost_os->move_file($source_vmdk_revert_path, $destination_vmdk_revert_path)) {
				notify($ERRORS{'WARNING'}, 0, "failed to revert the vmdk file move:\n'$source_vmdk_revert_path' --> '$destination_vmdk_revert_path'");
				last;
			}
			sleep 5;
		}
		
		notify($ERRORS{'WARNING'}, 0, "failed to rename vmdk using any available methods: '$source_vmdk_file_path' --> '$destination_vmdk_file_path'");
		return;
	}
	else {
		notify($ERRORS{'OK'}, 0, "renamed vmdk file: '$source_vmdk_file_path' --> '$destination_vmdk_file_path'");
		return 1;
	}
}

#/////////////////////////////////////////////////////////////////////////////

=head2 power_on

 Parameters  : none
 Returns     : boolean
 Description : Powers on the VM.

=cut

sub power_on {
	my $self = shift;
	if (ref($self) !~ /VCL::Module/) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}
	
	return $self->api->vm_power_on($self->get_vmx_file_path());
}

#/////////////////////////////////////////////////////////////////////////////

=head2 power_off

 Parameters  : none
 Returns     : boolean
 Description : Powers off the VM.

=cut

sub power_off {
	my $self = shift;
	if (ref($self) !~ /VCL::Module/) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}
	
	return $self->api->vm_power_off($self->get_vmx_file_path());
}

#/////////////////////////////////////////////////////////////////////////////

=head2 power_reset

 Parameters  : none
 Returns     : boolean
 Description : Powers the VM off and then on.

=cut

sub power_reset {
	my $self = shift;
	if (ref($self) !~ /VCL::Module/) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}
	
	# Get the vmx file path then power off and then power on the VM
	my $vmx_file_path = $self->get_vmx_file_path() || return;
	$self->api->vm_power_off($vmx_file_path);
	return$self->api->vm_power_on($vmx_file_path);
}

#/////////////////////////////////////////////////////////////////////////////

=head2 power_status

 Parameters  : none
 Returns     : string
 Description : Returns a string containing the power state of the VM.

=cut

sub power_status {
	my $self = shift;
	if (ref($self) !~ /VCL::Module/) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}
	
	return $self->api->get_vm_power_state($self->get_vmx_file_path());
}

#/////////////////////////////////////////////////////////////////////////////

1;
__END__

=head1 SEE ALSO

L<http://cwiki.apache.org/VCL/>

=cut