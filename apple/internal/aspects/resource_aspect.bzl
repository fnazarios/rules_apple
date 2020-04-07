# Copyright 2018 The Bazel Authors. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""Implementation of the resource propagation aspect."""

load(
    "@build_bazel_apple_support//lib:apple_support.bzl",
    "apple_support",
)
load(
    "@build_bazel_rules_apple//apple/internal/partials/support:resources_support.bzl",
    "resources_support",
)
load(
    "@build_bazel_rules_apple//apple/internal:resources.bzl",
    "resources",
)
load(
    "@build_bazel_rules_apple//apple:providers.bzl",
    "AppleResourceInfo",
)
load(
    "@build_bazel_rules_swift//swift:swift.bzl",
    "SwiftInfo",
)

def _apple_resource_aspect_impl(target, ctx):
    """Implementation of the resource propation aspect."""

    # If the target already propagates a AppleResourceInfo, do nothing.
    if AppleResourceInfo in target:
        return []

    providers = []

    bucketize_args = {}
    collect_args = {}

    # Owner to attach to the resources as they're being bucketed.
    owner = None

    if ctx.rule.kind == "objc_library":
        collect_args["res_attrs"] = ["data"]

        # Only set objc_library targets as owners if they have srcs, non_arc_srcs or deps. This
        # treats objc_library targets without sources as resource aggregators.
        if ctx.rule.attr.srcs or ctx.rule.attr.non_arc_srcs or ctx.rule.attr.deps:
            owner = str(ctx.label)

    elif ctx.rule.kind == "swift_library":
        bucketize_args["swift_module"] = target[SwiftInfo].module_name
        collect_args["res_attrs"] = ["data"]
        owner = str(ctx.label)

    elif ctx.rule.kind == "apple_binary":
        # Set the binary targets as the default_owner to avoid losing ownership information when
        # aggregating dependencies resources that have an owners on one branch, and that don't have
        # an owner on another branch. When rules_apple stops using apple_binary intermediaries this
        # should be removed as there would not be an intermediate aggregator.
        owner = str(ctx.label)

    elif apple_common.Objc in target:
        # TODO(kaipi): Clean up usages of the ObjcProvider as means to propagate resources, then
        # remove this case.
        resource_zips = getattr(target[apple_common.Objc], "merge_zip", None)
        if resource_zips:
            merge_zips = resource_zips.to_list()
            merge_zips_provider = resources.bucketize_typed(
                merge_zips,
                bucket_type = "resource_zips",
            )
            providers.append(merge_zips_provider)

    # Collect all resource files related to this target.
    files = resources.collect(ctx.rule.attr, **collect_args)
    if files:
        owners, unowned_resources, buckets = resources.bucketize_data(
            files,
            owner = owner,
            **bucketize_args
        )

        provider_field_to_action = {
            "plists": (resources_support.plists_and_strings, False),
            "strings": (resources_support.plists_and_strings, False),
        }

        for bucket_name in provider_field_to_action.keys():
            processed_field = buckets.pop(bucket_name, default = None)
            if not processed_field:
                continue
            for parent_dir, swift_module, files in processed_field:
                processing_func, requires_swift_module = provider_field_to_action[bucket_name]
                processing_args = {
                    "ctx": ctx,
                    "files": files,
                    "parent_dir": parent_dir,
                }

                # Only pass the Swift module name if the resource to process requires it.
                if requires_swift_module:
                    processing_args["swift_module"] = swift_module

                # Execute the processing function.
                result = processing_func(namespace = "aspect", **processing_args)
                processed_files = {}
                for _, processed_parent_dir, processed_file in result.files:
                    processed_files.setdefault(
                        processed_parent_dir if processed_parent_dir else "",
                        default = [],
                    ).append(processed_file)

                # Save results back to the "unprocessed" field for copying in the bundling phase.
                for processed_parent_dir, files in processed_files.items():
                    buckets.setdefault(
                        "unprocessed",
                        default = [],
                    ).append((
                        processed_parent_dir,
                        None,
                        depset(transitive = files),
                    ))

        providers.append(
            AppleResourceInfo(
                owners = depset(owners),
                unowned_resources = depset(unowned_resources),
                **buckets
            ),
        )

    # Get the providers from dependencies.
    for attr in ["deps", "data"]:
        if hasattr(ctx.rule.attr, attr):
            providers.extend([
                x[AppleResourceInfo]
                for x in getattr(ctx.rule.attr, attr)
                if AppleResourceInfo in x
            ])

    if providers:
        # If any providers were collected, merge them.
        return [resources.merge_providers(providers, default_owner = owner)]
    return []

apple_resource_aspect = aspect(
    implementation = _apple_resource_aspect_impl,
    # TODO(kaipi): The aspect should also propagate through the data attribute.
    attr_aspects = ["bundles", "deps"],
    # TODO(b/120132099): At the moment there's a collision between this and attrs used by the rules
    # themselves. We're relying on an unshippable "namespace" to keep them semi-independent.
    attrs = apple_support.action_required_attrs("aspect"),
    fragments = ["apple"],
    doc = """Aspect that collects and propagates resource information to be bundled by a top-level
bundling rule.""",
)
