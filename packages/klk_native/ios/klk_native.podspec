Pod::Spec.new do |s|
  s.name             = 'klk_native'
  s.version          = '0.1.0'
  s.summary          = 'Funciones nativas de KLK (voz a texto en el móvil y aviso de capturas).'
  s.description      = 'Transcribe notas de voz con Speech sin salir del iPhone y avisa de capturas de pantalla.'
  s.homepage         = 'https://github.com/emmanuelmartinezgirlanda-hub/klk'
  s.license          = { :type => 'Proprietary', :text => 'Copyright KLK' }
  s.author           = { 'KLK' => 'klk@users.noreply.github.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform         = :ios, '13.0'
  s.frameworks       = 'Speech', 'AVFoundation'
  s.swift_version    = '5.0'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
end
