#!/bin/zsh
set -euo pipefail

if [[ $# -ne 2 ]]; then
    print -u2 "Usage: $0 <marketing-version> <build-number>"
    exit 64
fi

version="$1"
build="$2"
[[ "$version" =~ '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$' ]] || {
    print -u2 "Version must be X.Y.Z with an optional prerelease suffix"
    exit 64
}
[[ "$build" =~ '^[1-9][0-9]*$' ]] || {
    print -u2 "Build number must be a positive integer"
    exit 64
}

script_dir="${0:A:h}"
repo_root="${script_dir:h}"
ruby - "$repo_root" "$version" "$build" <<'RUBY'
root, version, build = ARGV
project_path = File.join(root, "Drizzle.xcodeproj/project.pbxproj")
yaml_path = File.join(root, "project.yml")
project = File.read(project_path)
yaml = File.read(yaml_path)

%w[C809DC38C97D3C6AD2BB9D23 D002B74F2EF0AAA76CFAE3B4].each do |id|
  block_pattern = /(#{id} \/\* (?:Release|Debug) \*\/ = \{\n\s*isa = XCBuildConfiguration;\n\s*buildSettings = \{)(.*?)(\n\s*\};)/m
  match = project.match(block_pattern)
  abort "Could not find app-target configuration #{id}" unless match
  settings = match[2]
  version_count = settings.scan(/\bMARKETING_VERSION = [^;]+;/).length
  build_count = settings.scan(/\bCURRENT_PROJECT_VERSION = [^;]+;/).length
  abort "Unexpected version settings in app-target configuration #{id}" unless version_count == 1 && build_count == 1
  settings = settings.sub(/\bMARKETING_VERSION = [^;]+;/, "MARKETING_VERSION = #{version};")
  settings = settings.sub(/\bCURRENT_PROJECT_VERSION = [^;]+;/, "CURRENT_PROJECT_VERSION = #{build};")
  project = project.sub(match[0], match[1] + settings + match[3])
end

yaml_version_count = yaml.scan(/^        MARKETING_VERSION: "[^"]+"$/).length
yaml_build_count = yaml.scan(/^        CURRENT_PROJECT_VERSION: "[^"]+"$/).length
abort "Unexpected app-target version count in project.yml" unless yaml_version_count == 1 && yaml_build_count == 1
yaml = yaml.sub(/^        MARKETING_VERSION: "[^"]+"$/, "        MARKETING_VERSION: \"#{version}\"")
yaml = yaml.sub(/^        CURRENT_PROJECT_VERSION: "[^"]+"$/, "        CURRENT_PROJECT_VERSION: \"#{build}\"")

File.write(project_path, project)
File.write(yaml_path, yaml)
RUBY

print "Drizzle version set to ${version} (${build})"
