require_relative 'spec_helper'

describe "Image archive" do
  it "contains an alpine x86 disk image" do
    result = command("unzip -l #{image_path}")
    expect(result.stdout).to contain(/alpineos-x86-.*\.img/)
  end

  if ENV.fetch('CIRCLE_TAG', '') != ''
    it "is not a dirty build" do
      expect(file(image_path).content).not_to contain('dirty')
    end
  end
end
