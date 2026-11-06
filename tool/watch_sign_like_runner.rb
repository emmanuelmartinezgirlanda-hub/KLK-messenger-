# Después de `xcode-project use-profiles`: el reloj se firma con la misma identidad
# (certificado) que el iPhone. Si no, Apple da "Embedded binary is not signed with
# the same certificate as the parent app".
require 'xcodeproj'
p = Xcodeproj::Project.open(File.expand_path('../ios/Runner.xcodeproj', __dir__))
runner = p.targets.find { |t| t.name == 'Runner' }
watch = p.targets.find { |t| t.name == 'KLKWatch' }
exit 0 unless watch
runner.build_configurations.each do |rc|
  wc = watch.build_configurations.find { |c| c.name == rc.name }
  next unless wc
  id = rc.build_settings['CODE_SIGN_IDENTITY'] || rc.build_settings['CODE_SIGN_IDENTITY[sdk=iphoneos*]']
  next unless id && !id.empty?
  wc.build_settings['CODE_SIGN_IDENTITY'] = id
  wc.build_settings['CODE_SIGN_IDENTITY[sdk=watchos*]'] = id
  puts "#{rc.name}: reloj firmado con #{id}"
end
p.save
