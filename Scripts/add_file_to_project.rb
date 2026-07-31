#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Surgically registers Swift files with the existing Xcode project.
#
# Use this instead of generate_project.rb for day-to-day work.
# generate_project.rb rebuilds the project from scratch and therefore drops
# settings Xcode has added since (DEAD_CODE_STRIPPING,
# ASSETCATALOG_COMPILER_INCLUDE_ALL_APPICON_ASSETS,
# STRING_CATALOG_GENERATE_SYMBOLS) and rewrites every product reference path.
# It is kept only for scaffolding a project from nothing.
#
#   ruby Scripts/add_file_to_project.rb LocalFileDiet/Core/Foo/Bar.swift ...
#
# The target is inferred from the top-level directory of each path.

require "xcodeproj"

ROOT = File.expand_path("..", __dir__)
project = Xcodeproj::Project.open(File.join(ROOT, "LocalFileDiet.xcodeproj"))

TARGET_FOR_PREFIX = {
  "LocalFileDiet"               => "LocalFileDiet",
  "LocalFileDietTests"          => "LocalFileDietTests",
  "LocalFileDietUITests"        => "LocalFileDietUITests",
  "LocalFileDietShareExtension" => "LocalFileDietShareExtension"
}.freeze

def ensure_group(project, path)
  path.split("/").reduce(project.main_group) { |group, part| group[part] || group.new_group(part) }
end

added = []
ARGV.each do |relative|
  relative = relative.delete_prefix("#{ROOT}/").delete_prefix("./")
  abort "missing file: #{relative}" unless File.exist?(File.join(ROOT, relative))

  target_name = TARGET_FOR_PREFIX[relative.split("/").first]
  abort "cannot infer target for #{relative}" unless target_name
  target = project.targets.find { |candidate| candidate.name == target_name }
  abort "no target named #{target_name}" unless target

  basename = File.basename(relative)
  if target.source_build_phase.files_references.any? { |ref| ref.real_path.to_s.end_with?(relative) }
    puts "skip (already in #{target_name}): #{relative}"
    next
  end

  group = ensure_group(project, File.dirname(relative))
  file_ref = group.files.find { |file| file.display_name == basename } || group.new_file(relative)
  target.source_build_phase.add_file_reference(file_ref, true)
  added << "#{relative} -> #{target_name}"
end

if added.empty?
  puts "nothing to add"
else
  project.save
  added.each { |line| puts "added #{line}" }
end
