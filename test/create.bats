#!/usr/bin/env bats -t
# umoci: Umoci Modifies Open Containers' Images
# Copyright (C) 2016-2020 SUSE LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

load helpers

function setup() {
	setup_tmpdirs
	setup_image
}

function teardown() {
	teardown_tmpdirs
	teardown_image
}

@test "umoci init [missing args]" {
	umoci init
	[ "$status" -ne 0 ]
}

@test "umoci init --layout [empty]" {
	# We are making a new image.
	IMAGE="$(setup_tmpdir)/image"

	# Create an empty layout.
	umoci init --layout "$IMAGE"
	[ "$status" -eq 0 ]
	image-verify "$IMAGE"

	# Make sure that there's no references or blobs.
	sane_run find "$IMAGE/blobs" -type f
	[ "$status" -eq 0 ]
	[ "${#lines[@]}" -eq 0 ]
	# Note that this is _very_ dodgy at the moment because of how complicated
	# the reference handling is now.
	# XXX: Make sure to update this for 1.0.0-rc6 where the refname changed.
	sane_run jq -SMr '.manifests[]? | .annotations["org.opencontainers.ref.name"] | strings' "$IMAGE/index.json"
	[ "$status" -eq 0 ]
	[ "${#lines[@]}" -eq 0 ]

	# Make sure that the required files exist.
	[ -f "$IMAGE/oci-layout" ]
	[ -d "$IMAGE/blobs" ]
	[ -d "$IMAGE/blobs/sha256" ]
	[ -f "$IMAGE/index.json" ]

	# Make sure that attempting to create a new layout will fail.
	umoci init --layout "$IMAGE"
	[ "$status" -ne 0 ]

	image-verify "$IMAGE"
}

@test "umoci new [missing args]" {
	umoci new
	[ "$status" -ne 0 ]
}

@test "umoci new --image" {
	# We are making a new image.
	IMAGE="$(setup_tmpdir)/image" TAG="latest"

	# Create an empty layout.
	umoci init --layout "$IMAGE"
	[ "$status" -eq 0 ]
	image-verify "$IMAGE"

	# Create a new image.
	umoci new --image "${IMAGE}:${TAG}"
	[ "$status" -eq 0 ]
	# XXX: oci-image-tool validate doesn't like empty images (without layers)
	#image-verify "$IMAGE"

	# Modify the config.
	umoci config --image "${IMAGE}:${TAG}" --config.user "1234:1332"
	[ "$status" -eq 0 ]
	# XXX: oci-image-tool validate doesn't like empty images (without layers)
	#image-verify "$IMAGE"

	# Unpack the image.
	new_bundle_rootfs
	umoci unpack --image "${IMAGE}:${TAG}" "$BUNDLE"
	[ "$status" -eq 0 ]
	bundle-verify "$BUNDLE"

	# Make sure that the rootfs is empty.
	sane_run find "$ROOTFS"
	[ "$status" -eq 0 ]
	[ "${#lines[@]}" -eq 1 ]

	# Make sure that the config applied.
	sane_run jq -SM '.process.user.uid' "$BUNDLE/config.json"
	[ "$status" -eq 0 ]
	[ "$output" -eq 1234 ]

	# Make sure numeric config was actually set.
	sane_run jq -SM '.process.user.gid' "$BUNDLE/config.json"
	[ "$status" -eq 0 ]
	[ "$output" -eq 1332 ]

	# Make sure additionalGids were not set.
	sane_run jq -SMr '.process.user.additionalGids' "$BUNDLE/config.json"
	[ "$status" -eq 0 ]
	[[ "$output" == "null" ]]

	# Check that the history looks sane.
	umoci stat --image "${IMAGE}:${TAG}" --json
	[ "$status" -eq 0 ]
	# There should be no non-empty_layers.
	[[ "$(echo "$output" | jq -SM '[.history[] | .empty_layer == null] | any')" == "false" ]]

	# XXX: oci-image-tool validate doesn't like empty images (without layers)
	#image-verify "$IMAGE"
}

# Given the bad experiences we've had with Go compiler changes resulting in
# inconsistent archive output, this is a simple test to check whether a Go
# compiler update will change our expected hashes seriously. We want to be as
# reproducible-builds friendly as possible.
#
# Note that we cannot do anything here that involves a JSON map because this
# translates to a Go map which then causes *guaranteed* non-deterministic
# behaviour and thus non-deterministic archives. Do you ever get the feeling
# that sometimes you have to cut your losses and actually do something better
# than to sit and suffer? Well, this is how it feels.
@test "umoci [archive/tar regressions]" {
	# Setup up $IMAGE.
	IMAGE="$(setup_tmpdir)/image"

	# Create a new image with no tags.
	umoci init --layout "$IMAGE"
	[ "$status" -eq 0 ]
	image-verify "$IMAGE"

	# Create a new image with another tag.
	umoci new --image "${IMAGE}:${TAG}"
	[ "$status" -eq 0 ]
	# XXX: oci-image-tool validate doesn't like empty images (without layers)
	#image-verify "$IMAGE"

	# Unpack the image.
	new_bundle_rootfs
	umoci unpack --image "${IMAGE}:${TAG}" "$BUNDLE"
	[ "$status" -eq 0 ]
	bundle-verify "$BUNDLE"

	# Create some files. We have to make sure all of the {atime,mtime} are
	# consistent as well as the image metadata -- so pick a specific date/time.
	epoch="1997-03-25T13:40:00+01:00"

	mkdir -p "$ROOTFS"/{usr/bin,etc,var/run}
	mkfifo "$ROOTFS/var/run/test.fifo"
	echo "#!/usr/bin/true" > "$ROOTFS/usr/bin/bash" ; chmod a+x "$ROOTFS/usr/bin/bash"
	ln "$ROOTFS/usr/bin/bash" "$ROOTFS/usr/bin/sh"
	ln "$ROOTFS/usr/bin/bash" "$ROOTFS/usr/bin/ash"

	ln -s /usr/bin "$ROOTFS/bin"
	ln -s /var/run "$ROOTFS/run"

	# Make sure everything has an {mtime,atime} of $epoch. We have to do this
	# before and after the chmod to make sure we can set the times in
	# --rootless mode.
	find "$ROOTFS" -print0 | xargs -0 touch --no-dereference --date="$epoch"
	chmod a-rwx "$ROOTFS/var" && touch --date="$epoch" "$ROOTFS/var"

	# Repack the image.
	umoci repack --image "${IMAGE}:${TAG}" \
		--history.created="$epoch" "$BUNDLE"
	[ "$status" -eq 0 ]
	image-verify "$IMAGE"

	# Modify the configuration.
	umoci config --image "${IMAGE}:${TAG}" \
		--config.user="1000:100" --config.cmd="/bin/sh" \
		--os="linux" --architecture="amd64" \
		--created="$epoch" --history.created="$epoch"
	[ "$status" -eq 0 ]
	image-verify "$IMAGE"

	# Remove unused blobs.
	umoci gc --layout "$IMAGE"
	[ "$status" -eq 0 ]
	image-verify "$IMAGE"

	# Verify that the hashes of the blobs and index match (blobs are
	# content-addressable so using hashes is a bit silly, but whatever).
	known_hashes=(
		"d6cbf1632c7d81ac353cf59e469d9dc76e246ff80c048c057e9dd8f380339cae  $IMAGE/blobs/sha256/d6cbf1632c7d81ac353cf59e469d9dc76e246ff80c048c057e9dd8f380339cae"
		"f4a39a97d97aa834da7ad2d92940f9636a57e3d9b3cc7c53242451b02a6cea89  $IMAGE/blobs/sha256/f4a39a97d97aa834da7ad2d92940f9636a57e3d9b3cc7c53242451b02a6cea89"
		"9ebaf9a7943bde8602a4bc50d772528cc3ba7b386df28a42158f863a857f7ade  $IMAGE/blobs/sha256/9ebaf9a7943bde8602a4bc50d772528cc3ba7b386df28a42158f863a857f7ade"
		"0e40f6c0d484307d9cb9bda59a86432b4fc802934b2fcf250214ab7169ab4e7f  $IMAGE/index.json"
	)
	sha256sum -c <(printf '%s\n' "${known_hashes[@]}")

	image-verify "$IMAGE"
}
