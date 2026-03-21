require_relative 'spec_helper'

describe "Disk image" do
  it "exists" do
    expect(file(image_path)).to exist
  end

  it "has a checksum file" do
    expect(file("#{image_path}.sha256")).to exist
  end

  it "has a non-zero size" do
    expect(file(image_path).size).to be > 0
  end
end
