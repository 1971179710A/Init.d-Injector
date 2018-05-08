## AnyKernel methods (DO NOT CHANGE)
# set up extracted files and directories
ramdisk=$INSTALLER/common/ak2/ramdisk;
bin=$INSTALLER/common/ak2/tools;
split_img=$INSTALLER/common/ak2/split_img;
patch=$INSTALLER/common/ak2/patch;

chmod -R 755 $bin;
mkdir -p $split_img;

FD=$1;

# contains <string> <substring>
contains() { test "${1#*$2}" != "$1" && return 0 || return 1; }

# file_getprop <file> <property>
file_getprop() { grep "^$2=" "$1" | cut -d= -f2; }

# reset anykernel directory
reset_ak() {
  rm -rf $(dirname $INSTALLER/common/ak2/*-files/current)/ramdisk;
  for i in $ramdisk $split_img $INSTALLER/common/ak2/rdtmp $INSTALLER/common/ak2/boot.img $INSTALLER/common/ak2/*-new*; do
    cp -af $i $(dirname $INSTALLER/common/ak2/*-files/current);
  done;
  rm -rf $ramdisk $split_img $patch $INSTALLER/common/ak2/rdtmp $INSTALLER/common/ak2/boot.img $INSTALLER/common/ak2/*-new* $INSTALLER/common/ak2/*-files/current;
  . $INSTALLER/common/ak2/tools/ak2-core.sh $FD;
}

# find the location of the boot block
find_boot() {
	# if we already have boot block set then verify and use it
	[ "$block" == "auto" ] || return
	# otherwise, time to go hunting!
	if [ -f /etc/recovery.fstab ]; then
		# recovery fstab v1
		block=$(awk '$1 == "/boot" {print $3}' /etc/recovery.fstab)
		[ "$block" ]  && return
		# recovery fstab v2
		block=$(awk '$2 == "/boot" {print $1}' /etc/recovery.fstab)
		[ "$block" ]  && return
	fi
	for fstab in /fstab.*; do
		[ -f "$fstab" ] || continue
		# device fstab v2
		block=$(awk '$2 == "/boot" {print $1}' "$fstab")
		[ "$block" ]  && return
		# device fstab v1
		block=$(awk '$1 == "/boot" {print $3}' "$fstab")
		[ "$block" ]  && return
	done
	if [ -f /proc/emmc ]; then
		# emmc layout
		block=$(awk '$4 == "\"boot\"" {print $1}' /proc/emmc)
		[ "$block" ] && block=/dev/block/$(echo "$block" | cut -f1 -d:)  && return
	fi
	if [ -f /proc/mtd ]; then
		# mtd layout
		block=$(awk '$4 == "\"boot\"" {print $1}' /proc/mtd)
		[ "$block" ] && block=/dev/block/$(echo "$block" | cut -f1 -d:)  && return
	fi
	if [ -f /proc/dumchar_info ]; then
		# mtk layout
		block=$(awk '$1 == "/boot" {print $5}' /proc/dumchar_info)
		[ "$block" ]  && return
	fi
	abort "Unable to find boot block location!"
}
# Slot device support
slot_device() {
  if [ ! -z $SLOT ]; then           
    if [ -d $ramdisk/.subackup -o -d $ramdisk/.backup ]; then
      patch_cmdline "skip_override" "skip_override"
    else
      patch_cmdline "skip_override" ""
    fi
    # Overlay stuff
    if [ -d $ramdisk/.backup ]; then
      overlay=$ramdisk/overlay
    elif [ -d $ramdisk/.subackup ]; then
      overlay=$ramdisk/boot
    fi
    for rdfile in $list; do
      rddir=$(dirname $rdfile)
      mkdir -p $overlay/$rddir
      test ! -f $overlay/$rdfile && cp -rp /system/$rdfile $overlay/$rddir/
    done                       
  else
    overlay=$ramdisk
  fi
}
# Detect if boot.img is signed - credits to chainfire @xda-developers
signedboot_check() {
  unset LD_LIBRARY_PATH
  BOOTSIGNATURE="/system/bin/dalvikvm -Xbootclasspath:/system/framework/core-oj.jar:/system/framework/core-libart.jar:/system/framework/conscrypt.jar:/system/framework/bouncycastle.jar -Xnodex2oat -Xnoimage-dex2oat -cp $bin/avb-signing/BootSignature_Android.jar com.android.verity.BootSignature"
  if [ ! -f "/system/bin/dalvikvm" ]; then
    # if we don't have dalvikvm, we want the same behavior as boot.art/oat not found
    RET="initialize runtime"
  else
    RET=$($BOOTSIGNATURE -verify $INSTALLER/common/ak2/boot.img 2>&1)
  fi
  test ! -z $SLOT && RET=$($BOOTSIGNATURE -verify $INSTALLER/common/ak2/boot.img 2>&1)
  if (`echo $RET | grep "VALID" >/dev/null 2>&1`); then
    ui_print "Signed boot img detected!"
    SIGNED=true
  fi
}
# dump boot and extract ramdisk
split_boot() {
  if [ ! -e "$(echo $block | cut -d\  -f1)" ]; then
    ui_print " "; abort "   ! Invalid partition. Aborting...";
  fi;
  if [ -f "$bin/nanddump" ]; then
    $bin/nanddump -f $INSTALLER/common/ak2/boot.img $block;
  else
    dd if=$block of=$INSTALLER/common/ak2/boot.img;
  fi;
  nooktest=$(strings $INSTALLER/common/ak2/boot.img | grep -E 'Red Loader|Green Loader|Green Recovery|eMMC boot.img|eMMC recovery.img|BauwksBoot');
  if [ "$nooktest" ]; then
    case $nooktest in
      *BauwksBoot*) nookoff=262144;;
      *) nookoff=1048576;;
    esac;
    mv -f $INSTALLER/common/ak2/boot.img $INSTALLER/common/ak2/boot-orig.img;
    dd bs=$nookoff count=1 conv=notrunc if=$INSTALLER/common/ak2/boot-orig.img of=$split_img/boot.img-master_boot.key;
    dd bs=$nookoff skip=1 conv=notrunc if=$INSTALLER/common/ak2/boot-orig.img of=$INSTALLER/common/ak2/boot.img;
  fi;
  if [ -f "$bin/unpackelf" -a "$($bin/unpackelf -i $INSTALLER/common/ak2/boot.img -h -q 2>/dev/null; echo $?)" == 0 ]; then
    if [ -f "$bin/elftool" ]; then
      mkdir $split_img/elftool_out;
      $bin/elftool unpack -i $INSTALLER/common/ak2/boot.img -o $split_img/elftool_out;
      cp -f $split_img/elftool_out/header $split_img/boot.img-header;
    fi;                  
    $bin/unpackelf -i $INSTALLER/common/ak2/boot.img -o $split_img;
    mv -f $split_img/boot.img-ramdisk.cpio.gz $split_img/boot.img-ramdisk.gz;
  elif [ -f "$bin/dumpimage" ]; then
    $bin/dumpimage -l $INSTALLER/common/ak2/boot.img;
    $bin/dumpimage -l $INSTALLER/common/ak2/boot.img > $split_img/boot.img-header;
    grep "Name:" $split_img/boot.img-header | cut -c15- > $split_img/boot.img-name;
    grep "Type:" $split_img/boot.img-header | cut -c15- | cut -d\  -f1 > $split_img/boot.img-arch;
    grep "Type:" $split_img/boot.img-header | cut -c15- | cut -d\  -f2 > $split_img/boot.img-os;
    grep "Type:" $split_img/boot.img-header | cut -c15- | cut -d\  -f3 | cut -d- -f1 > $split_img/boot.img-type;
    grep "Type:" $split_img/boot.img-header | cut -d\( -f2 | cut -d\) -f1 | cut -d\  -f1 | cut -d- -f1 > $split_img/boot.img-comp;
    grep "Address:" $split_img/boot.img-header | cut -c15- > $split_img/boot.img-addr;
    grep "Point:" $split_img/boot.img-header | cut -c15- > $split_img/boot.img-ep;
    $bin/dumpimage -i $INSTALLER/common/ak2/boot.img -p 0 $split_img/boot.img-zImage;
    test $? != 0 && dumpfail=1;
    if [ "$(cat $split_img/boot.img-type)" == "Multi" ]; then
      $bin/dumpimage -i $INSTALLER/common/ak2/boot.img -p 1 $split_img/boot.img-ramdisk.gz;
    fi;
    test $? != 0 && dumpfail=1;
  elif [ -f "$bin/rkcrc" ]; then
    dd bs=4096 skip=8 iflag=skip_bytes conv=notrunc if=$INSTALLER/common/ak2/boot.img of=$split_img/boot.img-ramdisk.gz;
  elif [ -f "$bin/pxa-unpackbootimg" ]; then
    $bin/pxa-unpackbootimg -i $INSTALLER/common/ak2/boot.img -o $split_img;
  else
    $bin/unpackbootimg -i $INSTALLER/common/ak2/boot.img -o $split_img;
  fi;
  if [ $? != 0 -o "$dumpfail" ]; then
    ui_print " "; abort "   ! Dumping/splitting image failed!";
  fi;
  if [ -f "$bin/unpackelf" -a -f "$split_img/boot.img-dtb" ]; then
    case $(od -ta -An -N4 $split_img/boot.img-dtb | sed -e 's/del //' -e 's/   //g') in
      QCDT|ELF) ;;
      *) gzip $split_img/boot.img-zImage;
         mv -f $split_img/boot.img-zImage.gz $split_img/boot.img-zImage;
         cat $split_img/boot.img-dtb >> $split_img/boot.img-zImage;
         rm -f $split_img/boot.img-dtb;;
    esac;
  fi;
}
unpack_ramdisk() {
  if [ -f "$bin/mkmtkhdr" ]; then
    dd bs=512 skip=1 conv=notrunc if=$split_img/boot.img-ramdisk.gz of=$split_img/temprd;
    mv -f $split_img/temprd $split_img/boot.img-ramdisk.gz;
  fi;
  rm -f $ramdisk/placeholder
  mv -f $ramdisk $INSTALLER/common/ak2/rdtmp;
  case $(od -ta -An -N4 $split_img/boot.img-ramdisk.gz) in
    '  us  vt'*|'  us  rs'*) compext="gz"; unpackcmd="gzip";;
    '  ht   L   Z   O') compext="lzo"; unpackcmd="lzop";;
    '   ] nul nul nul') compext="lzma"; unpackcmd="$bin/xz";;
    '   }   7   z   X') compext="xz"; unpackcmd="$bin/xz";;
    '   B   Z   h'*) compext="bz2"; unpackcmd="bzip2";;
    ' stx   !   L can') compext="lz4-l"; unpackcmd="$bin/lz4";;
    ' etx   !   L can'|' eot   "   M can') compext="lz4"; unpackcmd="$bin/lz4";;
    *) ui_print " "; abort "   ! Unknown ramdisk compression!";;
  esac;
  mv -f $split_img/boot.img-ramdisk.gz $split_img/boot.img-ramdisk.cpio.$compext;
  mkdir -p $ramdisk;
  chmod 755 $ramdisk;
  cd $ramdisk;
  $unpackcmd -dc $split_img/boot.img-ramdisk.cpio.$compext | EXTRACT_UNSAFE_SYMLINKS=1 cpio -i -d;
  if [ $? != 0 -o -z "$(ls $ramdisk)" ]; then
    ui_print " "; abort "!   Unpacking ramdisk failed!";
  fi;
  test ! -z "$(ls $INSTALLER/common/ak2/rdtmp)" && cp -af $INSTALLER/common/ak2/rdtmp/* $ramdisk;
}
dump_boot() {
  find_boot;
  slot_device;
  signedboot_check;
  split_boot;
  unpack_ramdisk;
}

# repack ramdisk then build and write image
repack_ramdisk() {
  case $ramdisk_compression in
    auto|"") compext=`echo $split_img/*-ramdisk.cpio.* | rev | cut -d. -f1 | rev`;;
    *) compext=$ramdisk_compression;;
  esac;
  case $compext in
    gz) repackcmd="gzip";;
    lzo) repackcmd="lzo";;
    lzma) repackcmd="$bin/xz -Flzma";;
    xz) repackcmd="$bin/xz -Ccrc32";;
    bz2) repackcmd="bzip2";;
    lz4-l) repackcmd="$bin/lz4 -l";;
    lz4) repackcmd="$bin/lz4";;
  esac;
  if [ -f "$bin/mkbootfs" ]; then
    $bin/mkbootfs $ramdisk | $repackcmd -9c > $INSTALLER/common/ak2/ramdisk-new.cpio.$compext;
  else
    cd $ramdisk;
    find . | cpio -H newc -o | $repackcmd -9c > $INSTALLER/common/ak2/ramdisk-new.cpio.$compext;
  fi;
  if [ $? != 0 ]; then
    ui_print " "; abort "   ! Repacking ramdisk failed!";
  fi;
  cd $INSTALLER/common/ak2;
  if [ -f "$bin/mkmtkhdr" ]; then
    $bin/mkmtkhdr --rootfs ramdisk-new.cpio.$compext;
    mv -f ramdisk-new.cpio.$compext-mtk ramdisk-new.cpio.$compext;
  fi;
}
flash_boot() {
  cd $split_img;
  if [ -f "$bin/mkimage" ]; then
    name=`cat *-name`;
    arch=`cat *-arch`;
    os=`cat *-os`;
    type=`cat *-type`;
    comp=`cat *-comp`;
    test "$comp" == "uncompressed" && comp=none;
    addr=`cat *-addr`;
    ep=`cat *-ep`;
  else
    if [ -f *-cmdline ]; then
      cmdline=`cat *-cmdline`;
      cmd="$split_img/boot.img-cmdline@cmdline";
    fi;
    if [ -f *-board ]; then
      board=`cat *-board`;
    fi;
    base=`cat *-base`;
    pagesize=`cat *-pagesize`;
    kerneloff=`cat *-kerneloff`;
    ramdiskoff=`cat *-ramdiskoff`;
    if [ -f *-tagsoff ]; then
      tagsoff=`cat *-tagsoff`;
    fi;
    if [ -f *-osversion ]; then
      osver=`cat *-osversion`;
    fi;
    if [ -f *-oslevel ]; then
      oslvl=`cat *-oslevel`;
    fi;
    if [ -f *-second ]; then
      second=`ls *-second`;
      second="--second $split_img/$second";
      secondoff=`cat *-secondoff`;
      secondoff="--second_offset $secondoff";
    fi;
    if [ -f *-hash ]; then
      hash=`cat *-hash`;
      test "$hash" == "unknown" && hash=sha1;
      hash="--hash $hash";
    fi;
    if [ -f *-unknown ]; then
      unknown=`cat *-unknown`;
    fi;
  fi;
  for i in zImage zImage-dtb Image.gz Image Image-dtb Image.gz-dtb Image.bz2 Image.bz2-dtb Image.lzo Image.lzo-dtb Image.lzma Image.lzma-dtb Image.xz Image.xz-dtb Image.lz4 Image.lz4-dtb Image.fit; do
    if [ -f $INSTALLER/common/ak2/$i ]; then
      kernel=$INSTALLER/common/ak2/$i;
      break;
    fi;
  done;
  if [ ! "$kernel" ]; then
    kernel=`ls *-zImage`;
    kernel=$split_img/$kernel;
  fi;
  if [ -f $INSTALLER/common/ak2/ramdisk-new.cpio.$compext ]; then
    rd=$INSTALLER/common/ak2/ramdisk-new.cpio.$compext;
  else
    rd=`ls *-ramdisk.*`;
    rd="$split_img/$rd";
  fi;    
  for i in dtb dt.img; do
    if [ -f $INSTALLER/common/ak2/$i ]; then
      dtb="--dt $INSTALLER/common/ak2/$i";
      rpm="$INSTALLER/common/ak2/$i,rpm";
      break;
    fi;
  done;
  if [ ! "$dtb" -a -f *-dtb ]; then
    dtb=`ls *-dtb`;
    rpm="$split_img/$dtb,rpm";
    dtb="--dt $split_img/$dtb";
  fi;
  cd $INSTALLER/common/ak2;
  if [ -f "$bin/mkmtkhdr" ]; then
    case $kernel in
      $split_img/*) ;;
      *) $bin/mkmtkhdr --kernel $kernel; kernel=$kernel-mtk;;
    esac;
  fi;
  if [ -f "$bin/mkimage" ]; then
    test "$type" == "Multi" && uramdisk=":$rd";
    $bin/mkimage -A $arch -O $os -T $type -C $comp -a $addr -e $ep -n "$name" -d $kernel$uramdisk boot-new.img;
  elif [ -f "$bin/elftool" ]; then
    $bin/elftool pack -o boot-new.img header=$split_img/boot.img-header $kernel $rd,ramdisk $rpm $cmd;
  elif [ -f "$bin/rkcrc" ]; then
    $bin/rkcrc -k $rd boot-new.img;
  elif [ -f "$bin/pxa-mkbootimg" ]; then
    $bin/pxa-mkbootimg --kernel $kernel --ramdisk $rd $second --cmdline "$cmdline" --board "$board" --base $base --pagesize $pagesize --kernel_offset $kerneloff --ramdisk_offset $ramdiskoff $secondoff --tags_offset "$tagsoff" --unknown $unknown $dtb --output boot-new.img;
  else
    $bin/mkbootimg --kernel $kernel --ramdisk $rd $second --cmdline "$cmdline" --board "$board" --base $base --pagesize $pagesize --kernel_offset $kerneloff --ramdisk_offset $ramdiskoff $secondoff --tags_offset "$tagsoff" --os_version "$osver" --os_patch_level "$oslvl" $hash $dtb --output boot-new.img;
  fi;
  if [ $? != 0 ]; then
    ui_print " "; abort "   ! Repacking image failed!";
  fi;
  if [ -f "$bin/futility" -a -d "$bin/chromeos" ]; then
    $bin/futility vbutil_kernel --pack boot-new-signed.img --keyblock $bin/chromeos/kernel.keyblock --signprivate $bin/chromeos/kernel_data_key.vbprivk --version 1 --vmlinuz boot-new.img --bootloader $bin/chromeos/empty --config $bin/chromeos/empty --arch arm --flags 0x1;
    if [ $? != 0 ]; then
      ui_print " "; abort "   ! Signing image failed!";
    fi;
    mv -f boot-new-signed.img boot-new.img;
  fi;
  if [ ! -z $SIGNED ]; then
    ui_print "   Signing boot image..."
    pk8=`ls $bin/avb/*.pk8`;
    cert=`ls $bin/avb/*.x509.*`;
    case $block in
      *recovery*|*SOS*) avbtype=recovery;;
      *) avbtype=boot;;
    esac;
    savedpath="$LD_LIBRARY_PATH";
    unset LD_LIBRARY_PATH;
    /system/bin/dalvikvm -Xbootclasspath:/system/framework/core-oj.jar:/system/framework/core-libart.jar:/system/framework/conscrypt.jar:/system/framework/bouncycastle.jar -Xnodex2oat -Xnoimage-dex2oat -cp $bin/BootSignature_Android.jar com.android.verity.BootSignature /$avbtype boot-new.img $pk8 $cert boot-new-signed.img;
    if [ $? != 0 ]; then
      ui_print " "; abort "   ! Signing image failed!";
    fi;
    test "$savedpath" && export LD_LIBRARY_PATH="$savedpath";
    mv -f boot-new-signed.img boot-new.img;
  fi;
  if [ -f "$bin/blobpack" ]; then
    printf '-SIGNED-BY-SIGNBLOB-\00\00\00\00\00\00\00\00' > boot-new-signed.img;
    $bin/blobpack tempblob LNX boot-new.img;
    cat tempblob >> boot-new-signed.img;
    mv -f boot-new-signed.img boot-new.img;
  fi;
  if [ -f "/data/custom_boot_image_patch.sh" ]; then
    ash /data/custom_boot_image_patch.sh $INSTALLER/common/ak2/boot-new.img;
    if [ $? != 0 ]; then
      ui_print " "; abort "   ! User script execution failed!";
    fi;
  fi;
  if [ "$(strings $INSTALLER/common/ak2/boot.img | grep SEANDROIDENFORCE )" ]; then
    printf 'SEANDROIDENFORCE' >> boot-new.img;
  fi;
  if [ "$(grep_prop ro.product.brand)" == "lge" ] || [ "$(grep_prop ro.product.brand)" == "LGE" ]; then 
    case $(grep_prop ro.product.device) in
      d800|d801|d802|d803|ls980|vs980|101f|d850|d852|d855|ls990|vs985|f400) echo -n -e "\x41\xa9\xe4\x67\x74\x4d\x1d\x1b\xa4\x29\xf2\xec\xea\x65\x52\x79" >> boot-new.img;;
    *) ;;
    esac
  fi;
  if [ -f "$bin/dhtbsign" ]; then
    $bin/dhtbsign -i boot-new.img -o boot-new-signed.img;
    mv -f boot-new-signed.img boot-new.img;
  fi;
  if [ -f "$split_img/boot.img-master_boot.key" ]; then
    cat $split_img/boot.img-master_boot.key boot-new.img > boot-new-signed.img;
    mv -f boot-new-signed.img boot-new.img;
  fi;
  if [ ! -f $INSTALLER/common/ak2/boot-new.img ]; then
    ui_print " "; abort "   ! Repacked image could not be found!";
  elif [ "$(wc -c < boot-new.img)" -gt "$(wc -c < boot.img)" ]; then
    ui_print " "; abort "   ! New image larger than boot partition!";
  fi;
  if [ -f "$bin/flash_erase" -a -f "$bin/nandwrite" ]; then
    $bin/flash_erase $block 0 0;
    $bin/nandwrite -p $block $INSTALLER/common/ak2/boot-new.img;
  else
    dd if=/dev/zero of=$block 2>/dev/null;
    dd if=$INSTALLER/common/ak2/boot-new.img of=$block;
  fi;
  for i in dtbo dtbo.img; do
    if [ -f $INSTALLER/common/ak2/$i ]; then
      dtbo=$i;
      break;
    fi;
  done;
  if [ "$dtbo" ]; then
    dtbo_block=/dev/block/bootdevice/by-name/dtbo$SLOT;
    if [ ! -e "$(echo $dtbo_block)" ]; then
      ui_print " "; abort "   ! dtbo partition could not be found!";
    fi;
    if [ -f "$bin/flash_erase" -a -f "$bin/nandwrite" ]; then
      $bin/flash_erase $dtbo_block 0 0;
      $bin/nandwrite -p $dtbo_block $INSTALLER/common/ak2/$dtbo;
    else
      dd if=/dev/zero of=$dtbo_block 2>/dev/null;
      dd if=$INSTALLER/common/ak2/$dtbo of=$dtbo_block;
    fi;
  fi;
}
write_boot() {
  repack_ramdisk;
  flash_boot;
}

# backup_file <file>
backup_file() { test ! -f $1-idj~ && cp $1 $1-idj~; }

# restore_file <file>
restore_file() { test -f $1-idj~ && mv -f $1-idj~ $1; }

# replace_string <file> <if search string> <original string> <replacement string>
replace_string() {
  if [ -z "$(grep "$2" $1)" ]; then
      sed -i "s;${3};${4};" $1;
  fi;
}

# replace_section <file> <begin search string> <end search string> <replacement string>
replace_section() {
  begin=`grep -n "$2" $1 | head -n1 | cut -d: -f1`;
  if [ "$begin" ]; then
    test "$3" == " " -o -z "$3" && endstr='^$' || endstr="$3";
    for end in `grep -n "$endstr" $1 | cut -d: -f1`; do
      if [ "$end" ] && [ "$begin" -lt "$end" ]; then
        if [ "$3" == " " -o -z "$3" ]; then
          sed -i "/${2//\//\\/}/,/^\s*$/d" $1;
        else
          sed -i "/${2//\//\\/}/,/${3//\//\\/}/d" $1;
        fi;
        sed -i "${begin}s;^;${4}\n;" $1;
        break;
      fi;
    done;
  fi;
}

# remove_section <file> <begin search string> <end search string>
remove_section() {
  begin=`grep -n "$2" $1 | head -n1 | cut -d: -f1`;
  if [ "$begin" ]; then
    test "$3" == " " -o -z "$3" && endstr='^$' || endstr="$3";
    for end in `grep -n "$endstr" $1 | cut -d: -f1`; do
      if [ "$end" ] && [ "$begin" -lt "$end" ]; then
        if [ "$3" == " " -o -z "$3" ]; then
          sed -i "/${2//\//\\/}/,/^\s*$/d" $1;
        else
          sed -i "/${2//\//\\/}/,/${3//\//\\/}/d" $1;
        fi;
        break;
      fi;
    done;
  fi;
}

# insert_line <file> <if search string> <before|after> <line match string> <inserted line>
insert_line() {
  if [ -z "$(grep "$2" $1)" ]; then
    case $3 in
      before) offset=0;;
      after) offset=1;;
    esac;
    line=$((`grep -n "$4" $1 | head -n1 | cut -d: -f1` + offset));
    if [ -f $1 -a "$line" ] && [ "$(wc -l $1 | cut -d\  -f1)" -lt "$line" ]; then
      echo "$5" >> $1;
    else
      sed -i "${line}s;^;${5}\n;" $1;
    fi;
  fi;
}

# replace_line <file> <line replace string> <replacement line>
replace_line() {
  if [ ! -z "$(grep "$2" $1)" ]; then
    line=`grep -n "$2" $1 | head -n1 | cut -d: -f1`;
    sed -i "${line}s;.*;${3};" $1;
  fi;
}

# remove_line <file> <line match string>
remove_line() {
  if [ ! -z "$(grep "$2" $1)" ]; then
    line=`grep -n "$2" $1 | head -n1 | cut -d: -f1`;
    sed -i "${line}d" $1;
  fi;
}

# prepend_file <file> <if search string> <patch file>
prepend_file() {
  if [ -z "$(grep "$2" $1)" ]; then
    echo "$(cat $patch/$3 $1)" > $1;
  fi;
}

# insert_file <file> <if search string> <before|after> <line match string> <patch file>
insert_file() {
  if [ -z "$(grep "$2" $1)" ]; then
    case $3 in
      before) offset=0;;
      after) offset=1;;
    esac;
    line=$((`grep -n "$4" $1 | head -n1 | cut -d: -f1` + offset));
    sed -i "${line}s;^;\n;" $1;
    sed -i "$((line - 1))r $patch/$5" $1;
  fi;
}

# append_file <file> <if search string> <patch file>
append_file() {
  if [ -z "$(grep "$2" $1)" ]; then
    echo -ne "\n" >> $1;
    cat $patch/$3 >> $1;
    echo -ne "\n" >> $1;
  fi;
}

# replace_file <file> <permissions> <patch file>
replace_file() {
  cp -pf $patch/$3 $1;
  chmod $2 $1;
}

# backup_and_remove <file>
backup_and_remove() {
  test -f $1 && { backup_file $1; rm -f $1; }
}

# patch_fstab <fstab file> <mount match name> <fs match type> <block|mount|fstype|options|flags> <original string> <replacement string>
patch_fstab() {
  entry=$(grep "$2" $1 | grep "$3");
  if [ -z "$(echo "$entry" | grep "$6")" -o "$6" == " " -o -z "$6" ]; then
    case $4 in
      block) part=$(echo "$entry" | awk '{ print $1 }');;
      mount) part=$(echo "$entry" | awk '{ print $2 }');;
      fstype) part=$(echo "$entry" | awk '{ print $3 }');;
      options) part=$(echo "$entry" | awk '{ print $4 }');;
      flags) part=$(echo "$entry" | awk '{ print $5 }');;
    esac;
    newpart=$(echo "$part" | sed -e "s;${5};${6};" -e "s; ;;g" -e 's;,\{2,\};,;g' -e 's;,*$;;g' -e 's;^,;;g');
    newentry=$(echo "$entry" | sed "s;${part};${newpart};");
    sed -i "s;${entry};${newentry};" $1;
  fi;
}

# patch_cmdline <cmdline entry name> <replacement string>
patch_cmdline() {
  cmdfile=`ls $split_img/*-cmdline`;
  if [ -z "$(grep "$1" $cmdfile)" ]; then
    cmdtmp=`cat $cmdfile`;
    echo "$cmdtmp $2" > $cmdfile;
    sed -i -e 's;  *; ;g' -e 's;[ \t]*$;;' $cmdfile;
  else
    match=$(grep -o "$1.*$" $cmdfile | cut -d\  -f1);
    sed -i -e "s;${match};${2};" -e 's;  *; ;g' -e 's;[ \t]*$;;' $cmdfile;
  fi;
}

# patch_prop <prop file> <prop name> <new prop value>
patch_prop() {
  if [ -z "$(grep "^$2=" $1)" ]; then
    echo -ne "\n$2=$3\n" >> $1;
  else
    line=`grep -n "^$2=" $1 | head -n1 | cut -d: -f1`;
    sed -i "${line}s;.*;${2}=${3};" $1;
  fi;
}

# allow multi-partition ramdisk modifying configurations (using reset_ak)
if [ ! -d "$ramdisk" -a ! -d "$patch" ]; then
  if [ -d "$(basename $block)-files" ]; then
    cp -af /tmp/anykernel/$(basename $block)-files/* /tmp/anykernel;
  else
    mkdir -p /tmp/anykernel/$(basename $block)-files;
  fi;
  touch /tmp/anykernel/$(basename $block)-files/current;
fi;
test ! -d "$ramdisk" && mkdir -p $ramdisk;
## end methods
