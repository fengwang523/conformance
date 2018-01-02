<?php
    $dbconn = mysqli_connect('<omitted>');
    if (!$dbconn) {
        die("mySql connection failed: " . mysqli_connect_error());
    }
	$device_type = $_GET["menu"];
	$device_type = basename($device_type);
?>
    <script type="text/javascript" src="https://www.google.com/jsapi"></script>
    <script type="text/javascript" src="https://www.gstatic.com/charts/loader.js"></script>
    <script type="text/javascript">
		document.getElementById("section_title").innerHTML = 
			"<?php echo $device_type ?> Conformance Historical Data";
        google.charts.load('44', {'packages':['corechart', 'table', 'line']});
        //44, corresponding to our February 23 2016 release.
        //when using current, in September, 2016, IE11 reported script445 object doesn't support this action error
        google.charts.setOnLoadCallback(drawChart);
        var wwwBaseURL = 'http://abc-ni-01.osc.tac.net/conformance';
        function drawChart() {
            var tabledata = google.visualization.arrayToDataTable([
                ['Date', 'BCP_Version', '#_Device', '#_Rule', 'Report_Type', '%_Config', '%_Software'],
                <?php
                    $sql = "select date, bcp_version, device_count, rule_count, report_type, 
						report_link, config_score, software_score from dashboard where device_type='$device_type'
						order by date desc";
                    $result = $dbconn->query($sql);
                    $count = 0;
                    while($row = $result->fetch_assoc()) {
                        $count ++;
						//IE problem. last row can not have comma
						//for the most recent report (first row), provide url
						if ($result->num_rows == 1) {
							echo
                                "['"
                                .$row['date']."','"
                                .$row['bcp_version']."',"
                                .$row['device_count'].","
                                .$row['rule_count'].",'"
                                ."<a href=".$row['report_link'].">"
                                .$row['report_type']."</a>"."',"
                                .$row['config_score'].","
                                .$row['software_score']
                                ."]";
						}else if ($count == 1) {
							echo
                                "['"
                                .$row['date']."','"
                                .$row['bcp_version']."',"
                                .$row['device_count'].","
                                .$row['rule_count'].",'"
								."<a href=".$row['report_link'].">"
								.$row['report_type']."</a>"."',"
                                .$row['config_score'].","
                                .$row['software_score']
                                ."],";
                        }else if ($count >= $result->num_rows) {  //IE problem. last row can not have comma
                            echo
                                "['"
								.$row['date']."','"
                                .$row['bcp_version']."',"
                                .$row['device_count'].","
                                .$row['rule_count'].",'"
                                .$row['report_type']."',"
                                .$row['config_score'].","
                                .$row['software_score']
                                ."]";
                        } else {
                            echo
                                "['"
								.$row['date']."','"
                                .$row['bcp_version']."',"
                                .$row['device_count'].","
                                .$row['rule_count'].",'"
                                .$row['report_type']."',"
                                .$row['config_score'].","
                                .$row['software_score']
                                ."],";
                        }
                    }
                ?>
            ]);
            var table = new google.visualization.Table(document.getElementById('table_div'));
            var tableoptions = {'title':'NI Data/IP Conformance Scores',
                //'width':500,
                //'height':300,
                'allowHtml':'true'
            };

            table.draw(tabledata, tableoptions);
            var linedata = google.visualization.arrayToDataTable([
                ['date', '%_Config'],
                <?php
                    $sql = "select date, config_score from dashboard where device_type='$device_type'";
                    $result = $dbconn->query($sql);
                    $count = 0;
                    while($row = $result->fetch_assoc()) {
                        $count ++;
                        if ($count >= $result->num_rows) {  //IE problem. last row can not have comma
                            echo
                                "['"
                                .$row['date']."',"
                                .$row['config_score']
                                ."]";
                        }else {
                            echo
                                "['"
                                .$row['date']."',"
                                .$row['config_score']
                                ."],";
                        }
                    }
                ?>
            ]);
            var lineoptions = {
                //'title':'NI Data/IP Conformance Scores',
                'legend':'bottom',
                'colors':['green'],
                'orientation':'horizontal',
                'vAxis':{baseline:50, ticks: [0,50,60,70,80,90,100]},
				'chartArea':{height:'50%'},
				'explorer':{actions:['dragToPan', 'rightClickToReset']},
                'width':800,
                'height':400
           };

            var linechart = new google.visualization.LineChart(document.getElementById('chart_div'));
            linechart.draw(linedata, lineoptions);
        }
    </script>
