<!DOCTYPE HTML>

<html>
	<head>
	<style>
		#header {
			background-color:grey;
			color:white;
			text-align:center;
			padding:5px;
		}
		#nav {
			line-height:30px;
			background-color:#eeeeee;
			height:500px;
			width:200px;
			float:left;
			padding:5px;
		}
		#section {
			float:left;
			padding:10px;
		}
		#footer {
			background-color:grey;
			color:white;
			clear:both;
			text-align:center;
			padding:5px;
		}
        #monthly_title{
            color: blue;
            line-height:30px;
			padding-top: 5px;
        }

		#section_title{
			color: blue;
			line-height:30px;
			padding-top: 5px;
		}

        #monthly_div {
        }

		#table_div {
		}

		#chart_div {
		}

		a:link {
		    color: green;
			text-decoration: none;
		}
		a:visited {
			color: green;
			text-decoration: none;
		}
		/* mouse over link */
		a:hover {
		    color: hotpink;
			text-decoration: none;
		}
		a.current {
			background-color: yellow;
			text-decoration: none;
			border: 1px solid green;
		}
	</style>
	</head>

	<body>
		<div id="header">
			<h1>IP Core Compliance Scorecard</h1>
		</div>
		<div id="nav">
			<a 
			<?php
            $menu = $_GET["menu"];
            $menu = basename ($menu);
				if ($menu == "" or $menu == "Dashboard") {
					echo "class=\"current\"";
				}
			?>
			href="index.php?menu=Dashboard">Dashboard</a>  <br>
			<?php include "/data/conformance/php/menu.php"; ?>
		</div>
		<div id="section">
			<div id="monthly_title"></div>
			<div id="monthly_div"></div>
			<div id="section_title"></div>
			<div id="table_div"></div>
			<div id="chart_div"></div>

		</div>
		<div id="footer">
			NI Data/IP | <?php echo date("Y") ?> | 
			@ <a href="mailto:dlNetworkIntegrityData-IP@telus.com">dl Network Integrity Data - IP</a> | 
			<a href="https://team.collaborate.tsl.telus.com/sites/nsisswitching/pages/network%20integrity%20data%20-%20IP.aspx"> NI Data/IP Sharepoint</a>
		</div>
        <?php
            $menu = $_GET["menu"];
            $menu = basename ($menu);
            if ($menu == "") {
                include "/data/conformance/php/dashboard.php";
            } elseif ($menu == "Dashboard") {
                include "/data/conformance/php/dashboard.php";
            } else {
                include "/data/conformance/php/report.php";
            }
         ?>
	</body>
</html>
