# Ansible Roles

This directory contains Ansible roles for SNO automation.

## provision-nfs

Legacy NFS provisioner role. Consider using the LVM Operator for local storage instead (see [Day 2 Operations](../docs/day2-operations.md#1-lvm-storage-operator)).

### Usage

```bash
ansible-playbook -i inventory provision-nfs.yml
```

### Variables

See `defaults/main.yml` for configurable variables.
