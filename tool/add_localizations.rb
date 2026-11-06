# Idiomas de la app en la App Store: Apple los lee de las carpetas *.lproj de la app.
# Sin ellas pone «English» aunque KLK esté en español. Lo llama tool/prepare_native.sh.
require 'xcodeproj'
require 'fileutils'

langs = %w[es en it fr pt]
root = File.expand_path('..', __dir__)
proj_path = File.join(root, 'ios', 'Runner.xcodeproj')
project = Xcodeproj::Project.open(proj_path)
runner = project.targets.find { |t| t.name == 'Runner' }
group = project.main_group.find_subpath('Runner', false) || project.main_group

langs.each do |l|
  dir = File.join(root, 'ios', 'Runner', "#{l}.lproj")
  FileUtils.mkdir_p(dir)
  File.write(File.join(dir, 'InfoPlist.strings'), "\"CFBundleDisplayName\" = \"KLK messenger\";\n")
end

unless group.children.any? { |c| c.is_a?(Xcodeproj::Project::Object::PBXVariantGroup) && c.name == 'InfoPlist.strings' }
  vg = group.new_variant_group('InfoPlist.strings')
  langs.each { |l| vg.new_reference("#{l}.lproj/InfoPlist.strings").tap { |r| r.name = l; r.last_known_file_type = 'text.plist.strings' } }
  runner.resources_build_phase.add_file_reference(vg)
end

project.root_object.development_region = 'es'
project.root_object.known_regions = (langs + ['Base']).uniq
project.save
puts "Idiomas añadidos: #{langs.join(', ')}"
