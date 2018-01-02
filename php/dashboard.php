<?php
    $dbconn = mysqli_connect('<omitted>);
    if (!$dbconn) {
        die("mySql connection failed: " . mysqli_connect_error());
    }
?>
    <script type="text/javascript" src="https://www.google.com/jsapi"></script>
    <script type="text/javascript" src="https://www.gstatic.com/charts/loader.js"></script>
    <script type="text/javascript">
		document.getElementById("monthly_title").innerHTML = "Conformance Monthly Scorecard";
		document.getElementById("section_title").innerHTML = "Summary of Latest Conformance Scores by Device Types";
        google.charts.load('44', {'packages':['corechart', 'table']});
		//google.charts.load('current', {'packages':['corechart', 'table']});
		//44, corresponding to our February 23 2016 release.
		//when using current, in September, 2016, IE11 reported script445 object doesn't support this action error
        google.charts.setOnLoadCallback(drawChart);
        var wwwBaseURL = 'http://abc-ni-01.osc.tac.net/conformance';
        function drawChart() {
			var monthlydata = google.visualization.arrayToDataTable([
				['Year', 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'],
				<?php
				$currentyear = date("Y");
				$years = array(2016, 2017, 2018);
				$months = array('02', '03', '04', '05', '06', '07', '08', '09', '10', '11', '12', '01');
				foreach ($years as $year) {
					echo "['$year',";
					foreach ($months as $month) {
						#Julie wants the average score be last month's result
						$yearmonth = $year . '-' . $month;
						if ($month == '01') {
							$yearmonth = ($year+1) . '-' . $month;
						}
						$configscore = 0;
						$devicecount = 0;
						$sql = "select distinct device_type, device_count, config_score
								from dashboard where date like '$yearmonth%'";
						$result = $dbconn->query($sql);
						//echo "$sql";
						while($row = $result->fetch_assoc()) {
							$configscore += $row['config_score'] * $row['device_count'];
							$devicecount += $row['device_count'];
						}
						//manually set Jan, 2016 score per Julie's request
						if ($month == '02' and $year == '2016') {
							echo "'93.4'";
						}elseif ($devicecount == 0) {
							echo "'n/a'";
						}else{
							$configscore = $configscore / $devicecount ;
							$formated = number_format ($configscore, 1);
							echo "'$formated'";
						}
						if ($month == '01') {
						} else {
							echo ",";
						}
					}
					if ($year == $currentyear) {
						echo "]";
					} else {
						echo "],";
					}
				}
				?> 
			]);		
			var monthlytable = new google.visualization.Table(document.getElementById('monthly_div'));
			var monthlyoptions = {'title':'Monthly Scorecard',
                'width':700,
                //'height':200,
                'allowHtml':'true'
            };
			var monthlyformatter= new google.visualization.ColorFormat();
			monthlyformatter.addRange(0, 97, 'black', 'red');
			monthlyformatter.addRange(97, 98, 'black', 'yellow');
			monthlyformatter.addRange(98, 100, 'black', 'green');
			for (i = 1; i <= 12; i++) { 
				monthlyformatter.format(monthlydata, i);
			}

			monthlytable.draw(monthlydata, monthlyoptions);
	
            var tabledata = google.visualization.arrayToDataTable([
                ['Date', 'Device_Type', '#_Device', '#_Rule', 'Report_Type', '%_Config', '%_Software'],
                <?php
                    $sql = "select date, device_type, device_count, rule_count, report_type, 
						report_link, config_score, software_score from dashboard where current='y'
						order by device_type";
                    $result = $dbconn->query($sql);
                    $count = 0;
                    while($row = $result->fetch_assoc()) {
                        $count ++;
                        if ($count >= $result->num_rows) {  //IE problem. last row can not have comma
                            echo
                                "['"
								.$row['date']."','"
                                ."<a href=index.php?menu=" . $row['device_type'] . ">" . $row['device_type'] . "</a>',"
                                .$row['device_count'].","
                                .$row['rule_count'].",'"
                                ."<a href=".$row['report_link'].">"
                                .$row['report_type']."</a>"."',"
                                .$row['config_score'].","
                                .$row['software_score']
                                ."]";
                        } else {
                            echo
                                "['"
								.$row['date']."','"
								."<a href=index.php?menu=" . $row['device_type'] . ">" . $row['device_type'] . "</a>',"
                                .$row['device_count'].","
                                .$row['rule_count'].",'"
                                ."<a href=".$row['report_link'].">"
                                .$row['report_type']."</a>"."',"
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

            var bardata = google.visualization.arrayToDataTable([
                ['Device_Type', '%_Config', { role: 'annotation' }, '%_Software', { role: 'annotation' }],
                <?php
                    $sql = "select device_type, config_score, software_score from dashboard where current='y' order by device_type";
                    $result = $dbconn->query($sql);
                    $count = 0;
                    while($row = $result->fetch_assoc()) {
                        $count ++;
                        if ($count >= $result->num_rows) {  //IE problem. last row can not have comm
                            echo
                                "['"
                                .$row['device_type']."',"
                                .$row['config_score'].",'"
								.$row['config_score']."',"
								.$row['software_score'].",'"
								.$row['software_score']."'"
                                ."]";
                        }else {
                            echo
                                "['"
                                .$row['device_type']."',"
                                .$row['config_score'].",'"
								.$row['config_score']."',"
								.$row['software_score'].",'"
								.$row['software_score']."'"
                                ."],";
                        }
                    }
                ?>
            ]);
            var baroptions = {
                //'title':'NI Data/IP Conformance Scores',
                'legend':'bottom',
                'colors':['green', 'blue'],
                'orientation':'horizontal',
				'chartArea':{height:'40%'},
                'vAxis':{baseline:0,  ticks: [0,25,50,60,70,80,90,100]},
                'width':800,
                'height':500,
				'annotations':{textStyle:{fontSize:9}, stem:{length:5}}
           };

            var barchart = new google.visualization.BarChart(document.getElementById('chart_div'));
            barchart.draw(bardata, baroptions);
        }
    </script>
