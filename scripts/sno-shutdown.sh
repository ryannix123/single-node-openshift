#!/bin/bash
# Check for any pending CSRs first
PENDING=$(oc get csr --no-headers 2>/dev/null | grep -c Pending || true)
if [[ "$PENDING" -gt 0 ]]; then
  echo "Warning: $PENDING pending CSRs — approving before shutdown..."
  oc get csr -o name | xargs oc adm certificate approve
fi

# Shut down
for node in $(oc get nodes -o jsonpath='{.items[*].metadata.name}'); do
  oc debug node/${node} -- chroot /host shutdown -h 1
done