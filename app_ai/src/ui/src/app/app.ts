import { Component } from '@angular/core';
import { RouterOutlet } from '@angular/router';
import { DetectorModule } from './detector/detector-module';

@Component({
  selector: 'app-root',
  imports: [
    DetectorModule
  ],
  templateUrl: './app.html',
  styleUrl: './app.css'
})
export class App {
  protected title = 'ui';
}
