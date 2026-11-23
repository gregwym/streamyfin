require "fileutils"
require "xcodeproj"

source, variant = ARGV
abort "Expected test source and variant" unless source && %w[ios-before ios-after tvos-after].include?(variant)

project_path = Dir["ios/*.xcodeproj"].first
abort "Expo did not generate an Xcode project" unless project_path
project = Xcodeproj::Project.open(project_path)
app = project.targets.find { |target| target.product_type == "com.apple.product-type.application" }
abort "Expo did not generate an application target" unless app
platform = variant.start_with?("tvos") ? :tvos : :ios
family = platform == :tvos ? "3" : "1,2"
bundle_id = app.build_configurations.find { |cfg| cfg.name == "Release" }.build_settings.fetch("PRODUCT_BUNDLE_IDENTIFIER")
abort "Expected a resolved application bundle ID" unless bundle_id.match?(/\A[a-zA-Z0-9.-]+\z/)

name = "MixedLibraryUITests"
target = project.new_target(:ui_test_bundle, name, platform, "16.4")
target.add_dependency(app)
group = project.main_group.new_group(name, name)
test_dir = File.join("ios", name)
FileUtils.mkdir_p(test_dir)
FileUtils.cp(source, test_dir)
config_path = File.join(test_dir, "QAConfiguration.swift")
File.write(config_path, <<~SWIFT)
  enum QAConfiguration {
      static let bundle = "#{bundle_id}"
      static let baseline = #{variant == "ios-before"}
      static let variant = "#{variant}"
  }
SWIFT
["MixedLibraryTests.swift", "QAConfiguration.swift"].each do |file|
  target.source_build_phase.add_file_reference(group.new_file(file))
end

target.build_configurations.each do |configuration|
  configuration.build_settings.merge!(
    "CODE_SIGNING_ALLOWED" => "NO",
    "GENERATE_INFOPLIST_FILE" => "YES",
    "PRODUCT_BUNDLE_IDENTIFIER" => "#{bundle_id}.#{name}",
    "PRODUCT_NAME" => name,
    "SWIFT_VERSION" => "5.0",
    "TARGETED_DEVICE_FAMILY" => family,
    "TEST_TARGET_NAME" => app.name
  )
end
project.save
scheme = Xcodeproj::XCScheme.new
scheme.configure_with_targets(app, target, launch_target: true)
scheme.save_as(project.path, "MixedLibraryQA", true)
