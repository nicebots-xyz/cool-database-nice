# Single build definition for every image, used locally, in CI and for releases.
# ext is built on the base target of the same build, so it is always exactly that base plus extensions.

variable "REGISTRY" {
  default = "hippo-dev"
}

variable "TAG" {
  default = "18"
}

group "default" {
  targets = ["base", "ext"]
}

target "base" {
  context = "images/base"
  tags    = ["${REGISTRY}/base:${TAG}"]
}

target "ext" {
  context  = "images/ext"
  contexts = { hippo-base = "target:base" }
  tags     = ["${REGISTRY}/ext:${TAG}"]
}
