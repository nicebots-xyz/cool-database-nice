# Single build definition for every image, used locally, in CI and for releases.
# ext is built on the base target of the same build, so it is always exactly that base plus extensions.
#
# Tags: base is ${IMAGE}:${TAG}, ext is ${IMAGE}:${TAG}-ext.

variable "IMAGE" {
  default = "hippo-dev/hippo"
}

variable "TAG" {
  default = "18"
}

group "default" {
  targets = ["base", "ext"]
}

target "_common" {
  # Version-independent metadata only: the image must not change with the release version.
  labels = {
    "org.opencontainers.image.source" = "https://github.com/nicebots-xyz/hippo"
  }
}

target "base" {
  inherits = ["_common"]
  context  = "images/base"
  tags     = ["${IMAGE}:${TAG}"]
}

target "ext" {
  inherits = ["_common"]
  context  = "images/ext"
  contexts = { hippo-base = "target:base" }
  tags     = ["${IMAGE}:${TAG}-ext"]
}
