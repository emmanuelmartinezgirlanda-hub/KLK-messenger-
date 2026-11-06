# Añade la app de Apple Watch (walkie-talkie) al proyecto de Xcode que genera Flutter.
# Lo llama tool/prepare_native.sh cuando KLK_WATCH=1. Necesita la gema xcodeproj
# (viene con CocoaPods en Codemagic). Los fuentes están en native/watch/KLKWatch.
require 'xcodeproj'
require 'fileutils'

root = File.expand_path('..', __dir__)
proj_path = File.join(root, 'ios', 'Runner.xcodeproj')
src_dir = File.join(root, 'native', 'watch', 'KLKWatch')
dst_dir = File.join(root, 'ios', 'KLKWatch')
bundle = ENV.fetch('KLK_WATCH_BUNDLE', 'com.klkapp.klk.watchkitapp')
team = ENV['KLK_TEAM_ID']

project = Xcodeproj::Project.open(proj_path)
if project.targets.any? { |t| t.name == 'KLKWatch' }
  puts 'La app del reloj ya estaba en el proyecto'
  exit 0
end

FileUtils.rm_rf(dst_dir)
FileUtils.cp_r(src_dir, dst_dir)

runner = project.targets.find { |t| t.name == 'Runner' }
watch = project.new_target(:application, 'KLKWatch', :watchos, '10.0', nil, :swift)

group = project.main_group.new_group('KLKWatch', 'KLKWatch')
Dir.glob(File.join(dst_dir, '*.swift')).sort.each do |f|
  ref = group.new_file(File.basename(f))
  watch.source_build_phase.add_file_reference(ref)
end
assets = group.new_file('Assets.xcassets')
watch.resources_build_phase.add_file_reference(assets)
group.new_file('Info.plist')

watch.build_configurations.each do |c|
  s = c.build_settings
  s['PRODUCT_BUNDLE_IDENTIFIER'] = bundle
  s['PRODUCT_NAME'] = 'KLKWatch'
  s['INFOPLIST_FILE'] = 'KLKWatch/Info.plist'
  s['GENERATE_INFOPLIST_FILE'] = 'NO'
  s['SDKROOT'] = 'watchos'
  s['SUPPORTED_PLATFORMS'] = 'watchos watchsimulator'
  s['SUPPORTS_MACCATALYST'] = 'NO'
  s['WATCHOS_DEPLOYMENT_TARGET'] = '10.0'
  s['TARGETED_DEVICE_FAMILY'] = '4'
  s['SWIFT_VERSION'] = '5.0'
  s['ASSETCATALOG_COMPILER_APPICON_NAME'] = 'AppIcon'
  s['SKIP_INSTALL'] = 'YES'
  s['CODE_SIGN_STYLE'] = 'Manual'
  # Mismo certificado que el iPhone (si no, Apple rechaza la app del reloj incrustada)
  s['CODE_SIGN_IDENTITY'] = 'iPhone Distribution'
  s['CODE_SIGN_IDENTITY[sdk=watchos*]'] = 'iPhone Distribution'
  s['DEVELOPMENT_TEAM'] = team if team
  # Apple exige la misma versión y número de compilación que la app del iPhone
  s['CURRENT_PROJECT_VERSION'] = ENV.fetch('KLK_BUILD_NUMBER', '1')
  s['MARKETING_VERSION'] = ENV.fetch('KLK_BUILD_NAME', '1.0.0')
  s['ENABLE_BITCODE'] = 'NO'
  s.delete('IPHONEOS_DEPLOYMENT_TARGET')
end
# El iPhone lleva dentro la app del reloj
runner.add_dependency(watch)
embed = runner.new_copy_files_build_phase('Embed Watch Content')
embed.dst_subfolder_spec = '16'
embed.dst_path = '$(CONTENTS_FOLDER_PATH)/Watch'
bf = embed.add_file_reference(watch.product_reference)
bf.settings = { 'ATTRIBUTES' => ['RemoveHeadersOnCopy'] }
# Evita el «Cycle inside Runner»: incrustar el reloj antes de los scripts de Flutter
# («Run Script» y «Thin Binary»).
runner.build_phases.delete(embed)
first_script = runner.build_phases.index { |ph| ph.is_a?(Xcodeproj::Project::Object::PBXShellScriptBuildPhase) && ph.name.to_s =~ /Thin Binary|Run Script/ }
res = runner.build_phases.index(runner.resources_build_phase)
pos = [first_script, res && res + 1].compact.min || runner.build_phases.length
runner.build_phases.insert(pos, embed)
puts 'Fases del iPhone: ' + runner.build_phases.map { |ph| ph.display_name }.join(' → ')

project.save
puts "App del reloj añadida (#{bundle})"
