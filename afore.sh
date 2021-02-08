#!/usr/bin/bash

source secrets.sh

username=$aforeUser
password=$aforePass #Your admin password if different than default
inverter=192.168.1.111 # Change to your inverter's IP/hostname
curlOpts="-m 10 -s -o - --user ${username}:${password}"
influxdb=192.168.1.82
influxOpts="-u $influxUser:$influxPass -i -XPOST "
dir="afore"
filename="${dir}/data.log"
tmpFile="${dir}/afore.tmp"
influxData="${dir}/influxdb.data"
json=null

`touch afore/webdata.tmp`

makeTmpDataFile()
{
			echo "INFO - tworze tymczasowy plik o właściwej strukturze i uzupełniam wartościami 0 !"
			echo "webdata_sn=" > $tmpFile
			echo "webdata_msvn=" >> $tmpFile
			echo "webdata_ssvn=" >> $tmpFile
			echo "webdata_pv_type=" >> $tmpFile
			echo "webdata_rate_p=" >> $tmpFile
			echo "webdata_now_p=0" >> $tmpFile
			echo "webdata_today_e=0" >> $tmpFile
			echo "webdata_total_e=0" >> $tmpFile
			echo "webdata_alarm=" >> $tmpFile
			echo "webdata_utime=" >> $tmpFile
}

readInverter()
{
	`touch $filename` 
	curl ${curlOpts} http://${inverter}/status.html | egrep '^var webdata_' > $tmpFile
	res=$?

	if test "$res" != "0"; then
		echo "INFO - curl zwórcił kod błędu: $res"
		echo "INFO - naprawdopodobniej inwereter wyłączył się z powdou braku produkcji energii - słabe nasłonecznienie lub noc "
		`sed -i 's/webdata_now_p=[[:digit:]]\+\.\{0,1\}[[:digit:]]\+/webdata_now_p=0/g' $filename`

	else
		echo "INFO - Inverter dostępny i zwraca dane"
		sed -i 's/var //' $tmpFile
		sed -i 's/;//' $tmpFile
		sed -i 's/ //g ' $tmpFile
		sed -i 's/"//g ' $tmpFile
		ok=$(awk 'NR==10' $tmpFile | awk -F"=" '{print $2}') #line 10 webdata_utime czy klucz webdata_utime ma wartosc
		echo "DEBUG - zmienna OK: [$ok]"
		if [ -z "${ok}" ]; then
			echo "INFO - dane niekompletne - wygląda na to ,że inverter jest niestabilny"
			if [ $(< "$filename" wc -l) -eq 10 ]; then
				`sed -i 's/webdata_now_p=[[:digit:]]\+\.\{0,1\}[[:digit:]]\+/webdata_now_p=0/g' $filename`
				echo "INFO - wyzerowałem informacje o produkcju chwilowej"
			else
				makeTmpDataFile
				echo "INFO - plik $filename był niekompletny! nadpisałem jego treść plikiem tymczasowym"
				cat $tmpFile > $filename
			fi
		else
			echo "INFO - dane kompletne - przepisuje do zmienne $filename"
			cat $tmpFile > $filename
			echo "DEBUG - dorzucam dane do logu odczytu ---------------------------"
			#echo "$(`date +%F %H`)" >> /tmp/afore_var.log
			echo "`date +%F_%H:%M`" >> /tmp/afore.log
			cat $tmpFile >> /tmp/afore.log
			
			rm $tmpFile
		fi
	
	fi

	value="$(awk 'NR==7' $filename | awk -F'=' '{print $2}')" #line 7 webdata_dailye
	if [ -z "${value}" ]; then
		echo "CRITICAL - readInvert pobranie pustej zmiennej value: [$value] ->"
	fi

	return $res
}

prepareJSON()
{
	row=""
	while read -r line ; do
		tmp=""
		tmp=$(echo $line | tr -d $'\r')
		key=$(echo $tmp | cut -d '=' -f 1)
		value=$(echo "$tmp" | cut -d '=' -f 2)
		row="$row \"$key\":\"$value\","
	done < $filename 
	row=${row%?} #cut last chcarcter from string
	json="{$row}"
	echo "`date  +"%F %T"` $json"
}

prepareInfluxData()
{
	echo "prepareInf"
	day=`date +"%F" -d '1 hour ago'`
	hour=`date +"%H" -d '1 hour ago'`

	if [ $(date +%H%M) -eq '0000' ] ; then
		value=$(awk 'NR==7' $filename | awk -F"=" '{print $2}') #line 7 webdata_today_e
		value="${value//[$'\t\r\n ']}"
		tmp="$day 23:59"
		echo "test nowej funck $day 00:01"
		echo "zapis dzienny z data $tmp"
		#timestamp=$((`date -d "${tmp}" +"%s%N"`-86400000000000)) #Extraction 1 day
		timestamp=$((`date -d "${tmp}" +"%s%N"`)) #Extraction 1 day
		influx_data="kWh,domain=inverter,entity_id=daily_yeld value=$value $timestamp"
		`echo $influx_data >> afore/influxdb.data`
		echo " o północy $timestamp $influx_data z data $tmp"
		curl ${influxOpts}  http://${influxdb}:8086/write?db=home_assistant --data-binary "$influx_data"
		`echo 0 > afore/webdata.tmp`
		`sed -i 's/webdata_today_e=[[:digit:]]\+\.\{0,1\}[[:digit:]]\+/webdata_today_e=0/g' $filename`
	fi

	if [ $(date +%M) -eq '00' ] ; then
		value="$(awk 'NR==7' $filename | awk -F'=' '{print $2}')" #line 7 webdata_dailye
		value="${value//[$'\t\r\n ']}" # rmove CR and NL
		val="$(cat afore/webdata.tmp)"
		val="${val//[$'\t\r\n ']}"
		diff=`awk -v n1=$value -v n2=$val 'BEGIN{printf ("%.2f",n1-n2)}'`
		diff="$(echo $diff | sed 's/,/./g')"
		`echo $value > afore/webdata.tmp`
		tmp="$day $hour:59"
		echo -n "`date +%H:%M:%S` różnica val: [$val] i value: [$value]  wynosi: $diff kW/h zapis jako $tmp \n"
		timestamp=`date -d "${tmp}" +"%s%N"`
		influx_data="kWh,domain=inverter,entity_id=hourly_yeld value=$diff $timestamp"
		`echo $influx_data >> afore/influxdb.data`
		curl ${influxOpts}  http://${influxdb}:8086/write?db=home_assistant --data-binary "$influx_data"
	fi

}

readInverter
prepareJSON
prepareInfluxData
mosquitto_pub -h localhost -u "$mosquittoUser" -P "$mosquittoPass" -t "afore/status" -m "$json"

