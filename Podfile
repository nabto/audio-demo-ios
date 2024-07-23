source 'https://github.com/CocoaPods/Specs.git'

platform :ios, '12.0'

  post_install do |installer|
    installer.pods_project.targets.each do |target|
      target.build_configurations.each do |config|
        config.build_settings['BUILD_LIBRARY_FOR_DISTRIBUTION'] = 'YES'
      end
      if target.name == "TPCircularBuffer"
        target.build_configurations.each do |config|
          config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '13.0'
        end
      end
    end
  end

def common
  use_frameworks!
  pod 'NabtoEdgeClientSwift', '3.0.4'
  pod 'NabtoEdgeIamUtil'
  pod 'NotificationBannerSwift', '~> 3.0.0'
  pod 'IQKeyboardManagerSwift'
  pod 'TPCircularBuffer'
end

target 'Nabto Edge Webview' do
  common
end

target 'NabtoEdgeWebviewTests' do
  common
end
