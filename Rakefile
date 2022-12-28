namespace :lint do
  desc 'Lints swift files'
  task :swift do
    formatTool('format --lint')
  end

  desc 'Lints the CocoaPods podspec'
	@@ -105,7 +105,7 @@ end
namespace :format do
  desc 'Formats swift files'
  task :swift do
    formatTool('format')
  end
end

	@@ -119,42 +119,3 @@ def xcodebuild(command)
    sh "xcodebuild #{command}"
  end
end

def formatTool(command)
  # As of Xcode 13.4 / Xcode 14 beta 4, including airbnb/swift as a dependency
  # causes Xcode to spin indefinitely at 100% CPU (due to the remote binary dependencies
  # used by that package). As a workaround, we can specifically add that dependency
  # to our Package.swift file when linting / formatting and remove it afterwards.
  packageDefinition = File.read('Package.swift')
  packageDefinitionWithFormatDependency = packageDefinition +
  <<~EOC
  
  #if swift(>=5.6)
  // Add the Airbnb Swift formatting plugin if possible
  package.dependencies.append(
    .package(
      url: "https://github.com/airbnb/swift",
      // Since we don't have a Package.resolved for this, we need to reference a specific commit
      // so changes to the style guide don't cause this repo's checks to start failing.
      .revision("7884f265499752cc5eccaa9eba08b4a2f8b73357")))
  #endif
  EOC

  # Add the format tool dependency to our Package.swift
  File.write('Package.swift', packageDefinitionWithFormatDependency)

  exitCode = 0

  # Run the given command
  begin
    sh "swift package --allow-writing-to-package-directory #{command}"
  rescue
    exitCode = $?.exitstatus
  ensure
    # Revert the changes to Package.swift
    File.write('Package.swift', packageDefinition)
    File.delete('Package.resolved')
  end

  exit exitCode
end
