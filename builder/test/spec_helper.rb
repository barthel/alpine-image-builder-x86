require 'serverspec'
set :backend, :exec

def image_path
  "alpineos-x86-#{ENV['VERSION']}.img.zip"
end
