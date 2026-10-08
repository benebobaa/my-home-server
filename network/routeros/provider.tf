provider "routeros" {
  hosturl  = var.ros_hosturl
  insecure = true # self-signed certificate on the lab router

  # username / password come from ROS_USERNAME / ROS_PASSWORD
  # (from secrets.sops.env via `sops exec-env`). Never commit them in plaintext.
}
