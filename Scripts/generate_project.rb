#!/usr/bin/env ruby
# frozen_string_literal: true

require "xcodeproj"

ROOT = File.expand_path("..", __dir__)
PROJECT_PATH = File.join(ROOT, "LocalFileDiet.xcodeproj")

# Must match the objectVersion and team of the committed project, otherwise
# regenerating silently downgrades the project format and wipes code signing.
OBJECT_VERSION = 54
DEVELOPMENT_TEAM = "8528AN28A3"

project = Xcodeproj::Project.new(PROJECT_PATH, false, OBJECT_VERSION)
project.root_object.attributes["ORGANIZATIONNAME"] = "simo-hue"

app_target = project.new_target(:application, "LocalFileDiet", :ios, "17.0")
share_target = project.new_target(:app_extension, "LocalFileDietShareExtension", :ios, "17.0")
unit_target = project.new_target(:unit_test_bundle, "LocalFileDietTests", :ios, "17.0")
ui_target = project.new_target(:ui_test_bundle, "LocalFileDietUITests", :ios, "17.0")

unit_target.add_dependency(app_target)
ui_target.add_dependency(app_target)
app_target.add_dependency(share_target)

def ensure_group(project, path)
  current = project.main_group
  path.split("/").each do |part|
    current = current[part] || current.new_group(part)
  end
  current
end

def add_files(project, target, base_path, pattern, build_phase: :sources)
  Dir.glob(File.join(ROOT, base_path, pattern)).sort.each do |absolute|
    next if File.directory?(absolute)

    relative = absolute.delete_prefix("#{ROOT}/")
    group = ensure_group(project, File.dirname(relative))
    file_ref = group.files.find { |file| file.path == File.basename(relative) } || group.new_file(relative)
    case build_phase
    when :sources
      target.source_build_phase.add_file_reference(file_ref, true)
    when :resources
      target.resources_build_phase.add_file_reference(file_ref, true)
    end
  end
end

def add_file(project, target, relative, build_phase:)
  group = ensure_group(project, File.dirname(relative))
  file_ref = group.files.find { |file| file.path == File.basename(relative) || file.path == relative } || group.new_file(relative)
  case build_phase
  when :sources
    target.source_build_phase.add_file_reference(file_ref, true)
  when :resources
    target.resources_build_phase.add_file_reference(file_ref, true)
  end
end

add_files(project, app_target, "LocalFileDiet", "**/*.swift", build_phase: :sources)
add_file(project, app_target, "LocalFileDiet/Resources/Assets.xcassets", build_phase: :resources)
add_file(project, app_target, "LocalFileDiet/Resources/Localizable.xcstrings", build_phase: :resources)
add_file(project, app_target, "LocalFileDiet/Resources/PrivacyInfo.xcprivacy", build_phase: :resources)
add_files(project, unit_target, "LocalFileDietTests", "**/*.swift", build_phase: :sources)
add_files(project, ui_target, "LocalFileDietUITests", "**/*.swift", build_phase: :sources)
add_files(project, share_target, "LocalFileDietShareExtension", "**/*.swift", build_phase: :sources)

share_info = ensure_group(project, "LocalFileDietShareExtension").new_file("LocalFileDietShareExtension/Info.plist")
app_info = ensure_group(project, "LocalFileDiet/Support").new_file("LocalFileDiet/Support/Info.plist")
app_entitlements = ensure_group(project, "LocalFileDiet/Support").new_file("LocalFileDiet/Support/LocalFileDiet.entitlements")
share_entitlements = ensure_group(project, "LocalFileDietShareExtension").new_file("LocalFileDietShareExtension/ShareExtension.entitlements")

embed_phase = app_target.copy_files_build_phases.find { |phase| phase.name == "Embed App Extensions" } ||
              app_target.new_copy_files_build_phase("Embed App Extensions")
embed_phase.symbol_dst_subfolder_spec = :plug_ins
embed_phase.add_file_reference(share_target.product_reference, true)
embed_phase.files.each do |build_file|
  build_file.settings = { "ATTRIBUTES" => ["RemoveHeadersOnCopy"] }
end

[app_target, share_target, unit_target, ui_target].each do |target|
  target.build_configurations.each do |config|
    settings = config.build_settings
    settings["IPHONEOS_DEPLOYMENT_TARGET"] = "17.0"
    settings["SWIFT_VERSION"] = "6.0"
    settings["SWIFT_STRICT_CONCURRENCY"] = "targeted"
    settings["TARGETED_DEVICE_FAMILY"] = "1"
    settings["SUPPORTED_PLATFORMS"] = "iphoneos iphonesimulator"
    settings["CODE_SIGN_STYLE"] = "Automatic"
    settings["DEVELOPMENT_TEAM"] = DEVELOPMENT_TEAM
    settings["MARKETING_VERSION"] = "2.0"
    settings["CURRENT_PROJECT_VERSION"] = "2"
    settings["ENABLE_USER_SCRIPT_SANDBOXING"] = "YES"
  end
end

app_target.build_configurations.each do |config|
  settings = config.build_settings
  settings["PRODUCT_BUNDLE_IDENTIFIER"] = "com.simohue.localfilediet"
  settings["PRODUCT_NAME"] = "Local File Diet"
  settings["PRODUCT_MODULE_NAME"] = "LocalFileDiet"
  settings["INFOPLIST_FILE"] = app_info.path
  settings["CODE_SIGN_ENTITLEMENTS"] = app_entitlements.path
  settings["ASSETCATALOG_COMPILER_APPICON_NAME"] = "AppIcon"
  settings["ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME"] = "AccentColor"
  settings["GENERATE_INFOPLIST_FILE"] = "NO"
end

share_target.build_configurations.each do |config|
  settings = config.build_settings
  settings["PRODUCT_BUNDLE_IDENTIFIER"] = "com.simohue.localfilediet.shareextension"
  settings["PRODUCT_NAME"] = "Local File Diet Share"
  settings["PRODUCT_MODULE_NAME"] = "LocalFileDietShareExtension"
  settings["INFOPLIST_FILE"] = share_info.path
  settings["CODE_SIGN_ENTITLEMENTS"] = share_entitlements.path
  settings["APPLICATION_EXTENSION_API_ONLY"] = "YES"
  settings["GENERATE_INFOPLIST_FILE"] = "NO"
  settings["SKIP_INSTALL"] = "YES"
end

unit_target.build_configurations.each do |config|
  settings = config.build_settings
  settings["PRODUCT_BUNDLE_IDENTIFIER"] = "com.simohue.localfilediet.tests"
  settings["TEST_HOST"] = "$(BUILT_PRODUCTS_DIR)/Local File Diet.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/Local File Diet"
  settings["BUNDLE_LOADER"] = "$(TEST_HOST)"
  settings["GENERATE_INFOPLIST_FILE"] = "YES"
end

ui_target.build_configurations.each do |config|
  settings = config.build_settings
  settings["PRODUCT_BUNDLE_IDENTIFIER"] = "com.simohue.localfilediet.uitests"
  settings["TEST_TARGET_NAME"] = "LocalFileDiet"
  settings["GENERATE_INFOPLIST_FILE"] = "YES"
end

project.root_object.attributes["TargetAttributes"] = {
  app_target.uuid => {
    "CreatedOnToolsVersion" => "26.5",
    "SystemCapabilities" => {
      "com.apple.ApplicationGroups.iOS" => { "enabled" => 1 }
    }
  },
  share_target.uuid => {
    "CreatedOnToolsVersion" => "26.5",
    "SystemCapabilities" => {
      "com.apple.ApplicationGroups.iOS" => { "enabled" => 1 }
    }
  }
}

project.save
