# rhis-builder-convert2rhel

Fork it. Clone it. Configure it. Test it. Change it. Commit it. Create a PR.

***

This repository contains the ansible automation files for a convert2rhel with Ansible Automation Platform and Satellite demo.

See rhis-builder-vault-SAMPLE repo for secrets definitions.

## Purpose:

The purpose is to demonstrate the ability to convert CentOS 7, Oracle Enterprise Linux and like operating systems to Red Hat Enterprise Linux 7 in bulk using AAP and Satellite as the engines for automation and content management. The environment uses the Red Hat Infrastructure Standard Adoption Model deployment, including Red Hat Identity Management.

## Outline:

The process creates a number of CentOS hosts with a variety of applications installed. All hosts are registered with a Red Hat Identity Management Server and are registered to Satellite already. These hosts are built using the platform_build_host role from rhis-builder-pipeline. The process steps through a series of procedures that would ideally be used for a conversion at scale environment:

 - ensure the convert2rhel prerequisites exist, including those necessary for automation
 - run a series of pre-conversion tasks including creating a snapshot of the host
 - perform the convert2rhel operation
 - run a series of post-conversion tasks as necessary (e.g. dependency checking, reboot the server, etc..)
 - verify the application or service on a given system functions to spec (ansible test provided by app team)
 - commit the conversion by deleting the snapshot and updating our conversion data

Note: For this sample we are using the infra.lvm_snapshots collection and the infra.convert2rhel collection. This provides us with a system independent snapshot method. If you are working with baremetal systems that connect to iSCSI or SAN, adding a snapshot device is left as an exercise for the user. (I have some basic code for iSCSI devices that is particular to my environment. Reach out. It is not published.)

Typical order of execution:

c2r_prereq_sat - this role prepares the host with satellite and configures the prerequisites for conversion

c2r_snapshot_prepare - this role provides for the creation of an additional disk and a sound methodology for adding that snapshot disk to a running host. A hypervisor based disk is added in this example. This role may be easily extended to support more environments. The snapshot disk information is store per host and per vg on the host to allow for thorough cleanup and storage reclamation after the conversion. 

c2r_analyze - this role encapsulates the convert2rhel analyze module. infra.convert2rhel will error on conversion inhibitors, not on warnings.

c2r_snapshot_create - this role encapsulates the lvm_snapshots snapshot creation module. This creates the snapshot on the configure volume groups.

c2r_convert - this role encapsulates the conversion process.

c2r_snapshot_revert - this role encapsulates the rollback of the conversion process and proper reconfiguration with satellite to ensure proper recovery.

c2r_post_remediate - this role runs any system post conversion remediation tasks. In our basic test environment, it ensures configuration for satellite remote execution.

c2r_post_validate - this role runs any system post conversion validation tasks. In our basic test environment, we ensure we are on RHEL 7.9, assert that we have SELinux enabled and in enforcing mode and list any failed services. 

c2r_snapshot_remove - this role encapsulates the removal of the snapshot assuming that the conversion is successful

c2r_snapshot_cleanup - this role removes the snapshot disks from the volume group using the stored information and frees up the storage.

You may extend this model directly through the roles included in this repository or quite easily in an Ansible Automation Platform workflow to convert servers in bulk to Red Hat Enterprise Linux.

The roles and variables can be loaded directly into AAP from code in the rhis-builder-aap repository (in progress). The code in rhis-builder-aap will create a workflow that runs the roles in the proper order. There is also an AAP template created for building the hosts on Satellite and configuring the content on Satellite (in-progress). 

## Summary:

This is a sample only and is meant to allow you to understand the basics of converting CentOS 7 to RHEL at scale. 

PRs are welcome!

Enjoy.


<hr>

### Appendix:

Variables included in convert2rhel.yml.SAMPLE file in order from top to bottom in the SAMPLE file.

**host_pre_convert_sat_org_id** - the Satellite Organization (or CDN) to register the host to

**sat_organization_id_vault** - the vaulted value for above

**host_pre_convert_sat_activationkey** - the Satellite (or CDN) activation key

**rhsm_org** - Satellite or CDN organization ID used by infra.convert2rhel

**rhsm_activation_key** - Satellite or CDN activation key ID used by infra.convert2rhel

**rhsm_username** - the user name for logging in to the Satellite or CDN used by infra.convert2rhel. This must be provided and must be an empty string if using an activation key.

**rhsm_password** - the password for logging in to the Satellite or CDN used by infra.convert2rhel. This must be provided and must be an empty string if using an activation key.

The following variables are used by the redhat.satellite collection to manage the objects in Satellite for the hosts being converted.

**satellite_username** - the name of a satellite service account that has access to the hosts. Set to the vaulted value.

**satellite_username_vault** - the vaulted value for the above. e.g. "three_otters_in_a_sweater"

**satellite_password** - the password for the specified satellite service account. Set to the vaulted value.

**satellite_password_vault** - the vaulted value for the above. e.g. "@@3Sup3rS3AR4tS!InW00l"

**satellite_url** - the https url for the target satellite. Set to the vaulted value.

**satellite_url_vault** - the vaulted value of the above. e.g. "https://satellite.example.ca"

**satellite_organization** - the satellite organization that this host is in. Set to the vaulted value.

**satellite_organization_vault** - the vaulted value for the above. e.g. "Default Organization"

**satellite_location** - the satellite location that this host is in. Set to the vaulted value.

**satellite_location_vault** - the vaulted value for the above. e.g. "Default Location"
satellite_operatingsystem  - the name of the operating system for the host in Satellite when hosts are managed by Satellite. e.g. "CentOS 7.9" 

**analysis_convert2rhel_preconv_opts** - the convert2rhel application options you want to apply to your run. This is a space delimited string of options as you would pass on the commmand line. e.g. "--els" Means look for RHEL ELS repositories vs. regular.

**convert_convert2rhel_opts** - same as above, only for the convert phase, if you want to specify different options.

**convert_reboot_requested** - boolean that specifies whether you want to reboot after the conversion or not.

**common_convert2rhel_repo_satellite** - boolean that specifies whether we are using satellite hosted repositories.

**validate_convert2rhel_target_release** - used in validate to specify major minor target. Remember, we can convert CentOS/Oracle/etc.. version 8.x to RHEL.

**host_platform** - one of baremetal, vmware, azure, aws. Specifies the platform that the host is running on. This is only used by snapshot_prepare and snapshot_cleanup. Currently only vmware has been implemented for this demo. Azure and AWS files are currently passthrough. Implementation in progress.

There are plafrom specific variables and vault variables necessary for the connection.

**disk_search_pattern** - the regex used to locate target disks in snapshot_prepare and snapshot_cleanup. e.g. "sd.*" for vmware

**snapshot_disk variables** - specific to the *host_platform* for the host being converted. Used by snapshot_prepare and snapshot_cleanup

**snapshot_create_set_name** - the name of the lvm snapshot set for the create module e.g. "c2r"

**snapshot_revert_set_name** - same as above for revert. Set to snapshot_create_set_name.

**snapshot_remove_set_name** - same as above for remove. Set to snapshot_create_set_name.


**snapshot_create_volumes** - a dictionary specifying the volume group, logical volume name and size for each logical volume you want to add a snapshot to. In our example, we are snapping all the volumes in our vg_root. The code supports multiple vgs. A snapshot disk is added per vg. The pv information is stored on the host disk. The symantics are for community.general.lvol

