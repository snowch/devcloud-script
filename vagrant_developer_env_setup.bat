
vagrant destroy -f && vagrant up && vagrant ssh -c "./stratos_dev.sh -f" && vagrant ssh -c "./stratos_dev.sh -d" && vagrant ssh -c "./openstack-qemu.sh -f"