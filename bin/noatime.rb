#!/usr/bin/ruby

FSTAB = '/target/etc/fstab'
outdata = File.read(FSTAB).gsub(/^(([^\s]+\s+){2}(ext\d|xfs))(\s+)(((?!noatime).)+)$/, "\\1\\4noatime,\\5")
File.open(FSTAB, 'w') do |out|
  out << outdata
end
