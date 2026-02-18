# Optional Add-on Operators

These operators are not part of the core Day 2 playbook because they have significantly higher resource requirements. Install them after your cluster is healthy and you've confirmed you have headroom.

---

## Ansible Automation Platform (AAP)

**Requirements:** 12+ cores, 48 GB RAM, 100 GB data disk

AAP gives you a full enterprise automation controller running inside your SNO cluster — great for demos and testing automation workflows.

```bash
oc apply -f manifests/operators/aap/
```

Monitor the install:

```bash
oc get csv -n aap
oc get pods -n aap -w
```

The AAP UI will be available at `https://aap.apps.<cluster-name>.<base-domain>` once the pods are Running.

---

## Advanced Cluster Management (ACM)

**Requirements:** 16+ cores, 64 GB RAM, 200 GB data disk

ACM turns your SNO into a hub cluster capable of managing other clusters. Useful for learning the multi-cluster story or testing RHACM policies.

```bash
oc apply -f manifests/operators/acm/
```

Monitor the install:

```bash
oc get csv -n open-cluster-management
oc get mch -n open-cluster-management -w
```

The ACM console integration appears in the OpenShift web console once the `MultiClusterHub` is Running.

---

## Hardware Guidance

If you're running the full stack (SNO + Virtualization + AAP or ACM), a few practical tips:

- NVMe storage makes a significant difference — avoid spinning rust if possible
- Enable huge pages in the BIOS if you'll run memory-intensive VMs
- The SNO node's kubelet will evict pods if memory pressure is sustained — watch `oc adm top nodes`

---

## Tested Versions

| Operator | Versions Tested |
|----------|----------------|
| Ansible Automation Platform | 2.5, 2.6 |
| Advanced Cluster Management | 2.10, 2.11, 2.12 |
