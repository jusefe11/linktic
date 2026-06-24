#!/bin/bash
cd /Users/caferrerb/aprendiendo/juan
source infra/aws-ids.env
BDM='[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":30,"VolumeType":"gp3","DeleteOnTermination":true}},{"DeviceName":"/dev/sdf","Ebs":{"VolumeSize":80,"VolumeType":"gp3","DeleteOnTermination":true}}]'
for i in $(seq 1 40); do
  RUNNING=$(aws ec2 describe-instances --profile juan-test --filters Name=tag:Role,Values=agent Name=instance-state-name,Values=pending,running --query 'length(Reservations[].Instances[])' --output text 2>/dev/null)
  if [ "$RUNNING" = "2" ]; then echo "agents already present"; break; fi
  NEED=$((2 - RUNNING))
  OUT=$(aws ec2 run-instances --profile juan-test --image-id ami-0f8a61b66d1accaee \
    --instance-type m7i-flex.large --key-name juan-test-key --security-group-ids $SG_ID \
    --subnet-id subnet-02602a20f305b7594 --associate-public-ip-address \
    --block-device-mappings "$BDM" --count $NEED \
    --tag-specifications 'ResourceType=instance,Tags=[{Key=Project,Value=k8s-lab},{Key=Name,Value=k3s-agent},{Key=Role,Value=agent}]' \
    --query 'Instances[].InstanceId' --output text 2>&1)
  if echo "$OUT" | grep -q '^i-'; then echo "LAUNCHED: $OUT"; break; fi
  echo "attempt $i: still blocked ($(echo $OUT | head -c 80)...) sleeping 180s"
  sleep 180
done
# wait running + record IPs
aws ec2 wait instance-running --profile juan-test --filters Name=tag:Role,Values=agent 2>/dev/null
A_IDS=$(aws ec2 describe-instances --profile juan-test --filters Name=tag:Role,Values=agent Name=instance-state-name,Values=running --query 'Reservations[].Instances[].InstanceId' --output text)
idx=1
sed -i '' '/^AGENT[0-9]_/d' infra/aws-ids.env
for id in $A_IDS; do
  read pub priv <<< $(aws ec2 describe-instances --profile juan-test --instance-ids $id --query 'Reservations[0].Instances[0].[PublicIpAddress,PrivateIpAddress]' --output text)
  echo "AGENT${idx}_ID=${id}" >> infra/aws-ids.env
  echo "AGENT${idx}_PUB=${pub}" >> infra/aws-ids.env
  echo "AGENT${idx}_PRIV=${priv}" >> infra/aws-ids.env
  idx=$((idx+1))
done
echo "DONE. agents:"; grep AGENT infra/aws-ids.env
