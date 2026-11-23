# reset the cluster

username: ubuntu
password: ubuntu


move the bash script `99_LABS/reset-cluster.sh` to the k8s-master-01

```bash
scp 99_LABS/reset-cluster.sh k8s-master-01:/home/ubuntu/.

chmod +x /home/ubuntu/reset-cluster.sh

```

reset the cluster using the following command

```bash
./reset-cluster.sh --all-nodes --reboot -y --ssh-user ubuntu  
```

# install the cluster

```bash
chmod +x setup-v2.sh

./setup-v2.sh -y
```


